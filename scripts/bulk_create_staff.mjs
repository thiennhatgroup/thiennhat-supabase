// Bulk-create staff accounts: creates each person's Supabase Auth login
// (email + "tn-pin::<pin>" password) AND their matching `profiles` row
// (name + role) in one pass, instead of doing both by hand in the dashboard
// for every single person.
//
// This uses the SERVICE ROLE key, which has full admin access and bypasses
// Row Level Security entirely. NEVER put this key in public/config.js, NEVER
// commit it to git, NEVER share it. It only ever lives in your terminal's
// environment variables when you run this script locally.
//
// Usage:
//   1. cd scripts
//   2. npm install                       (one-time)
//   3. cp staff.example.json staff.local.json
//      ... then edit staff.local.json with your real people (this file is
//      gitignored — it will never be committed or pushed to GitHub)
//   4. Set two environment variables (see SUPABASE_SETUP.md section 8D for
//      exactly where to find these values), then run:
//        SUPABASE_URL="https://xxxx.supabase.co" \
//        SUPABASE_SERVICE_ROLE_KEY="eyJ..." \
//        npm run create-staff
//
// Safe to re-run: existing people are detected by email and only their
// profile (name/role/status) gets updated, they won't be duplicated.

import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.error('Missing environment variables.');
  console.error('You must set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY before running this script.');
  console.error('See SUPABASE_SETUP.md section 8D for exactly where to find these two values.');
  process.exit(1);
}

const staffFilePath = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(__dirname, 'staff.local.json');

if (!fs.existsSync(staffFilePath)) {
  console.error(`Staff file not found: ${staffFilePath}`);
  console.error('Copy scripts/staff.example.json to scripts/staff.local.json and fill in real people first.');
  process.exit(1);
}

const staff = JSON.parse(fs.readFileSync(staffFilePath, 'utf8'));
const ALLOWED_ROLES = ['NhanVienMuaHang', 'TruongPhong', 'KeToanCongNo', 'LanhDao', 'Admin'];

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

let okCount = 0;
let failCount = 0;

for (const person of staff) {
  const { email, pin, name, role } = person;
  const status = person.status || 'Hoạt động';

  if (!email || !pin || !name || !role) {
    console.error(`✘ Skipping invalid entry (needs email, pin, name, role): ${JSON.stringify(person)}`);
    failCount++;
    continue;
  }
  if (!ALLOWED_ROLES.includes(role)) {
    console.error(`✘ Skipping ${email}: role "${role}" must be one of ${ALLOWED_ROLES.join(', ')}`);
    failCount++;
    continue;
  }

  try {
    let userId;

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password: `tn-pin::${pin}`,
      email_confirm: true,
    });

    if (createErr) {
      const msg = String(createErr.message || '').toLowerCase();
      const alreadyExists = msg.includes('already been registered') || msg.includes('already exists');
      if (!alreadyExists) throw createErr;

      // Person already has an Auth login — look up their existing id instead
      // of failing, so re-running this script to update roles is safe.
      const { data: list, error: listErr } = await admin.auth.admin.listUsers();
      if (listErr) throw listErr;
      const existing = list.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
      if (!existing) throw createErr;
      userId = existing.id;
      console.log(`  (${email} already had a login — reusing it, updating their profile only)`);
    } else {
      userId = created.user.id;
    }

    const { error: profileErr } = await admin
      .from('profiles')
      .upsert({ id: userId, email, name, role, status }, { onConflict: 'id' });

    if (profileErr) throw profileErr;

    console.log(`✔ ${email} — ${role} — done`);
    okCount++;
  } catch (err) {
    console.error(`✘ ${email} — failed: ${err.message || err}`);
    failCount++;
  }
}

console.log(`\nFinished: ${okCount} succeeded, ${failCount} failed.`);
if (failCount > 0) process.exit(1);
