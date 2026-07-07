# Project Instructions

This is the Thiên Nhật purchasing/debt tracking app using Supabase RPCs and a single-page frontend.

## Rules

- Audit before editing.
- Keep changes slice-based and narrowly scoped.
- Do not rewrite old migrations; add a new migration that overrides active RPCs.
- Preserve the RPC-first security model.
- Do not switch to full RLS-everywhere unless explicitly approved.
- Do not revert unrelated user changes.
- For each slice, verify with available static checks.
- If Supabase CLI, psql, or Deno are unavailable, say so clearly.
- Commit only the current slice.