import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..');
const migrationsDir = path.join(repoRoot, 'supabase', 'migrations');
const outputFile = path.join(repoRoot, 'docs', 'ACTIVE_RPC_MAP.md');
const checkOnly = process.argv.includes('--check');

function lineNumberAt(text, index) {
  let line = 1;
  for (let i = 0; i < index; i += 1) {
    if (text.charCodeAt(i) === 10) line += 1;
  }
  return line;
}

function isLineCommented(text, index) {
  const lineStart = text.lastIndexOf('\n', index - 1) + 1;
  const before = text.slice(lineStart, index);
  return before.includes('--');
}

function findMatchingParen(text, openIndex) {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  let inLineComment = false;
  let inBlockComment = false;

  for (let i = openIndex; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inSingle) {
      if (ch === "'" && next === "'") {
        i += 1;
      } else if (ch === "'") {
        inSingle = false;
      }
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }

    if (ch === '-' && next === '-') {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === '/' && next === '*') {
      inBlockComment = true;
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === '(') depth += 1;
    if (ch === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function splitTopLevel(value) {
  const parts = [];
  let start = 0;
  let depth = 0;
  let inSingle = false;
  let inDouble = false;

  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    const next = value[i + 1];

    if (inSingle) {
      if (ch === "'" && next === "'") i += 1;
      else if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === '(') depth += 1;
    else if (ch === ')') depth -= 1;
    else if (ch === ',' && depth === 0) {
      parts.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }

  const tail = value.slice(start).trim();
  if (tail) parts.push(tail);
  return parts;
}

function stripDefault(value) {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;

  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    const next = value[i + 1];
    if (inSingle) {
      if (ch === "'" && next === "'") i += 1;
      else if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === '(') depth += 1;
    else if (ch === ')') depth -= 1;

    if (depth === 0) {
      const rest = value.slice(i);
      const defaultMatch = rest.match(/^\s+default\b/i);
      if (defaultMatch) return value.slice(0, i).trim();
      if (ch === '=') return value.slice(0, i).trim();
    }
  }

  return value.trim();
}

function normalizeType(value) {
  return value
    .trim()
    .replace(/^public\./i, '')
    .replace(/\s+/g, ' ')
    .replace(/\s*\[\s*\]/g, '[]')
    .toLowerCase();
}

function normalizeCreateArgs(argsText) {
  if (!argsText.trim()) return [];
  return splitTopLevel(argsText).map((arg) => {
    const withoutDefault = stripDefault(arg);
    const tokens = withoutDefault.split(/\s+/).filter(Boolean);
    if (!tokens.length) return '';
    let index = ['in', 'out', 'inout', 'variadic'].includes(tokens[0].toLowerCase()) ? 1 : 0;
    if (tokens.length - index >= 2) index += 1;
    return normalizeType(tokens.slice(index).join(' '));
  });
}

function normalizeSignatureArgs(argsText) {
  if (!argsText.trim()) return [];
  return splitTopLevel(argsText).map(normalizeType);
}

function signatureFor(name, argTypes) {
  return `${name.toLowerCase()}(${argTypes.join(',')})`;
}

function formatLocation(event) {
  return `${event.file}:${event.line}`;
}

function mdEscape(value) {
  return String(value).replaceAll('|', '\\|');
}

function joinLocations(events) {
  if (!events.length) return '-';
  return events.map(formatLocation).join('<br>');
}

function parseEvents(file, sql) {
  const events = [];
  const patterns = [
    { type: 'create', regex: /\bcreate\s+(?:or\s+replace\s+)?function\s+([a-zA-Z_][\w]*)\s*\(/gim },
    { type: 'drop', regex: /\bdrop\s+function\s+(?:if\s+exists\s+)?([a-zA-Z_][\w]*)\s*\(/gim },
    { type: 'grant', regex: /\bgrant\s+execute\s+on\s+function\s+([a-zA-Z_][\w]*)\s*\(/gim },
  ];

  for (const pattern of patterns) {
    for (const match of sql.matchAll(pattern.regex)) {
      const name = match[1];
      if (!name.toLowerCase().startsWith('rpc_')) continue;
      if (isLineCommented(sql, match.index)) continue;

      const openIndex = match.index + match[0].length - 1;
      const closeIndex = findMatchingParen(sql, openIndex);
      if (closeIndex < 0) continue;

      const argsText = sql.slice(openIndex + 1, closeIndex);
      const argTypes = pattern.type === 'create'
        ? normalizeCreateArgs(argsText)
        : normalizeSignatureArgs(argsText);
      const semicolon = sql.indexOf(';', closeIndex);
      const statementEnd = semicolon >= 0 ? semicolon : closeIndex;
      const statementTail = sql.slice(closeIndex + 1, statementEnd);

      if (pattern.type === 'grant' && !/\bto\b[\s\S]*\bauthenticated\b/i.test(statementTail)) {
        continue;
      }

      events.push({
        type: pattern.type,
        name: name.toLowerCase(),
        signature: signatureFor(name, argTypes),
        file: path.posix.join('supabase', 'migrations', file),
        line: lineNumberAt(sql, match.index),
      });
    }
  }

  return events.sort((a, b) => a.line - b.line);
}

function renderMarkdown(states, migrationCount) {
  const all = [...states.values()].sort((a, b) => a.signature.localeCompare(b.signature));
  const active = all.filter((state) => state.active);
  const retired = all.filter((state) => !state.active && state.definitions.length);
  const duplicateActive = active.filter((state) => state.definitions.length > 1);
  const granted = active.filter((state) => state.authenticatedGrant);

  const lines = [];
  lines.push('# Active RPC Ownership Map');
  lines.push('');
  lines.push('Generated from `supabase/migrations` by `scripts/generate_active_rpc_map.mjs`.');
  lines.push('');
  lines.push('Refresh with:');
  lines.push('');
  lines.push('```sh');
  lines.push('node scripts/generate_active_rpc_map.mjs');
  lines.push('```');
  lines.push('');
  lines.push('Check that the committed map is current with:');
  lines.push('');
  lines.push('```sh');
  lines.push('node scripts/generate_active_rpc_map.mjs --check');
  lines.push('```');
  lines.push('');
  lines.push('## Summary');
  lines.push('');
  lines.push(`- Migrations scanned: ${migrationCount}`);
  lines.push(`- Active RPC signatures: ${active.length}`);
  lines.push(`- Active RPC signatures granted to \`authenticated\`: ${granted.length}`);
  lines.push(`- Active RPC signatures with prior duplicate definitions: ${duplicateActive.length}`);
  lines.push(`- Retired/dropped RPC signatures: ${retired.length}`);
  lines.push('');
  lines.push('## Active RPCs');
  lines.push('');
  lines.push('| RPC signature | Active owner | Authenticated grant | Superseded definitions |');
  lines.push('| --- | --- | --- | --- |');
  for (const state of active) {
    const olderDefinitions = state.definitions.filter((event) => event !== state.activeOwner);
    lines.push(`| \`${mdEscape(state.signature)}\` | ${formatLocation(state.activeOwner)} | ${state.authenticatedGrant ? `Yes (${formatLocation(state.authGrantEvent)})` : 'No'} | ${joinLocations(olderDefinitions)} |`);
  }
  lines.push('');

  lines.push('## Duplicate Definition History');
  lines.push('');
  if (duplicateActive.length === 0) {
    lines.push('No active RPC signatures have duplicate definitions.');
  } else {
    for (const state of duplicateActive) {
      lines.push(`### \`${state.signature}\``);
      lines.push('');
      for (const event of state.definitions) {
        const marker = event === state.activeOwner ? 'active owner' : 'superseded';
        lines.push(`- ${formatLocation(event)} - ${marker}`);
      }
      lines.push('');
    }
  }

  lines.push('## Retired Or Dropped RPC Signatures');
  lines.push('');
  if (retired.length === 0) {
    lines.push('No retired RPC signatures were detected.');
  } else {
    lines.push('| RPC signature | Last definition | Retired by |');
    lines.push('| --- | --- | --- |');
    for (const state of retired) {
      lines.push(`| \`${mdEscape(state.signature)}\` | ${formatLocation(state.definitions.at(-1))} | ${formatLocation(state.lastDrop)} |`);
    }
  }
  lines.push('');

  return `${lines.join('\n').replace(/\n+$/, '')}\n`;
}

const migrationFiles = (await readdir(migrationsDir))
  .filter((file) => /^\d+_.*\.sql$/i.test(file))
  .sort((a, b) => a.localeCompare(b));

const states = new Map();

for (const file of migrationFiles) {
  const sql = await readFile(path.join(migrationsDir, file), 'utf8');
  for (const event of parseEvents(file, sql)) {
    if (!states.has(event.signature)) {
      states.set(event.signature, {
        signature: event.signature,
        definitions: [],
        drops: [],
        authenticatedGrant: false,
        authGrantEvent: null,
        active: false,
        activeOwner: null,
        lastDrop: null,
      });
    }

    const state = states.get(event.signature);
    if (event.type === 'create') {
      state.definitions.push(event);
      state.active = true;
      state.activeOwner = event;
      state.lastDrop = null;
    } else if (event.type === 'drop') {
      state.drops.push(event);
      state.active = false;
      state.activeOwner = null;
      state.lastDrop = event;
      state.authenticatedGrant = false;
      state.authGrantEvent = null;
    } else if (event.type === 'grant') {
      state.authenticatedGrant = true;
      state.authGrantEvent = event;
    }
  }
}

const markdown = renderMarkdown(states, migrationFiles.length);

if (checkOnly) {
  const current = await readFile(outputFile, 'utf8').catch(() => '');
  if (current !== markdown) {
    console.error('docs/ACTIVE_RPC_MAP.md is out of date. Run `node scripts/generate_active_rpc_map.mjs`.');
    process.exit(1);
  }
  console.log('docs/ACTIVE_RPC_MAP.md is current.');
} else {
  await writeFile(outputFile, markdown);
  console.log(`Wrote ${path.relative(repoRoot, outputFile)}`);
}
