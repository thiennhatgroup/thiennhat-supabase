-- ============================================================================
-- 0002_rls.sql
-- Deny-by-default posture, same philosophy as firestore.rules / storage.rules
-- in the sibling Firebase project: the browser NEVER talks to tables
-- directly. Every read/write goes through an RPC function defined with
-- SECURITY DEFINER further down (0004-0008), which runs with elevated
-- privileges and does its own role/permission checks against auth.uid().
--
-- Enabling RLS with *no* policies for authenticated/anon means: even with a
-- valid session, a client using supabase.from('debts').select() etc. gets
-- zero rows / a permission error. Only supabase.rpc(...) calls work.
-- ============================================================================

alter table app_config          enable row level security;
alter table profiles            enable row level security;
alter table role_permissions    enable row level security;
alter table doi_tuong           enable row level security;
alter table materials           enable row level security;
alter table price_quotes        enable row level security;
alter table proposals           enable row level security;
alter table proposal_lines      enable row level security;
alter table debts               enable row level security;
alter table payments            enable row level security;
alter table payment_allocations enable row level security;
alter table audit_log           enable row level security;
alter table code_counters       enable row level security;

-- Intentionally no CREATE POLICY statements: this is the "allow read, write:
-- if false" equivalent. All access happens via SECURITY DEFINER RPCs, which
-- are owned by the migration-running role (postgres) and therefore bypass
-- RLS for their own internal queries while still checking auth.uid() /
-- profiles.role themselves before doing anything.

-- Revoke the default table privileges PostgREST would otherwise expose.
revoke all on app_config, profiles, role_permissions, doi_tuong, materials,
  price_quotes, proposals, proposal_lines, debts, payments,
  payment_allocations, audit_log, code_counters
  from anon, authenticated;
