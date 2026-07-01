# Handoff brief — Thiên Nhật Supabase port

Context for continuing this project in a new chat. User (Huy) is switching to Claude Opus to debug code from here.

## What this project is

A full rewrite of a legacy Google Apps Script + Google Sheets web app ("Thiên Nhật — NVL mua hàng / công nợ" — materials purchasing / accounts-payable tracking) onto Supabase (Postgres + Auth) with a static HTML/JS frontend. The original `webapp.gs` + `Index.html` business logic (roles, permissions, FIFO payment settlement, AP/AR netting) was ported faithfully — same rules, same workflow, just relational storage instead of a spreadsheet.

Local project folder: `thiennhat-supabase/` inside the user's Claude Projects folder
`Phần mềm duyệt đề xuất mua hàng - theo dõi công nợ`.

GitHub repo: `https://github.com/thiennhatgroup/thiennhat-supabase` (org `thiennhatgroup`, owned by the user).

Supabase project: name "Thien Nhat" / "Purchasing software", project ref **`nsxvasvceslhhvgjkedh`**, Project URL `https://nsxvasvceslhhvgjkedh.supabase.co`.

Live frontend (GitHub Pages): `https://thiennhatgroup.github.io/thiennhat-supabase/` — deploy succeeded.

## Repo structure

```
thiennhat-supabase/
├── SUPABASE_SETUP.md          # very detailed beginner setup guide — kept in sync with everything done so far
├── README.md
├── .gitignore                  # includes scripts/staff.local.json (never commit real PINs)
├── supabase/
│   ├── config.toml             # project_id set to nsxvasvceslhhvgjkedh
│   ├── after_setup_create_admin.sql
│   └── migrations/              # run in order 0001 → 0010, applied via GitHub Actions (Option B)
│       0001_schema.sql   0002_rls.sql   0003_seed_reference.sql   0004_permissions.sql
│       0005_debts_view.sql   0006_rpc_bootstrap_quotes.sql   0007_rpc_proposals.sql
│       0008_rpc_receipts_payments.sql   0009_rpc_dashboard_settlement.sql   0010_rpc_recent.sql
├── public/
│   ├── index.html               # entire frontend, one file, supabase-js v2 via CDN
│   └── config.js                # supabaseUrl + supabaseAnonKey — already filled in correctly
├── scripts/
│   ├── bulk_create_staff.mjs    # optional: bulk-create Auth users + profiles from a JSON list
│   ├── staff.example.json       # template (safe to commit)
│   ├── staff.local.json         # gitignored, real staff list goes here (not yet used)
│   └── package.json
└── .github/workflows/
    ├── deploy-db.yml             # supabase db push on changes to supabase/migrations/**, or manual dispatch
    └── deploy-frontend.yml       # publishes public/ to GitHub Pages
```

## Architecture / security model

- Postgres tables: `app_config`, `profiles` (FK to `auth.users`, role check constraint: `NhanVienMuaHang`/`TruongPhong`/`KeToanCongNo`/`LanhDao`/`Admin`), `role_permissions`, `doi_tuong`, `materials`, `price_quotes`, `proposals`, `proposal_lines`, `debts` (has `is_archived` instead of the old "cut row to another sheet" trick), `payments`, `payment_allocations`, `audit_log`, `code_counters`.
- **Deny-by-default RLS**: every table has RLS enabled, zero policies, `revoke all from anon, authenticated`. All access goes through `SECURITY DEFINER` RPC functions (`rpc_bootstrap`, `rpc_create_proposal`, `rpc_approve_proposal`, `rpc_create_payment`, `rpc_preview_settlement`/`rpc_confirm_settlement`, etc.), each checking `has_permission()`/`require_permission()` against `role_permissions`.
- **Login trick**: Supabase Auth only does email+password, but the app's UX is "email + short PIN." The frontend silently turns a PIN into a password by prefixing it: PIN `1234` → password `tn-pin::1234`. Users only ever type the PIN; they never see or type the prefix. This must be remembered whenever creating/resetting a user's password in the Supabase dashboard — always type `tn-pin::<pin>` as the actual password there.
- FIFO settlement (oldest due date first, tie-broken by receive/approve/proposal date) and AP/AR netting-per-counterparty logic is preserved exactly from the original `compareCongNoItemsForSettlement_`/`buildDashboardSummary_`.

## Bugs found and fixed during this session

1. **Missing `dieu_khoan_tt` column** on `debts` — added; fixed two INSERT statements that referenced it (`rpc_approve_proposal`, advance-row insert in `rpc_create_payment`).
2. **Missing `set search_path = public, pg_temp`** on all `SECURITY DEFINER` functions — added across all 18 functions (security hardening).
3. **Non-idempotent DDL in `0001_schema.sql`** — this caused a real production failure: `alter table proposal_lines add constraint fk_proposal_lines_debt ...` and three `create trigger ...` statements had no "already exists" guard, unlike every other statement in the file (`create table if not exists`, etc.). When the GitHub Actions migration workflow was retried, it failed with `constraint "fk_proposal_lines_debt" already exists`. **Fixed**: wrapped the constraint in a `do $$ if not exists (select 1 from pg_constraint where conname = ...) then ... end if; end $$;` block, and changed the three triggers to `create or replace trigger` (supported Postgres 14+, Supabase runs newer). Verified with `pglast.parse_sql` — parses clean.
4. **`public/config.js` had the wrong `supabaseUrl`** — user had pasted the *dashboard page URL* (`https://supabase.com/dashboard/project/nsxvasvceslhhvgjkedh`) instead of the actual **API** Project URL (`https://nsxvasvceslhhvgjkedh.supabase.co`). Fixed directly in the file. This was the cause of "Failed to fetch" on the live site.
5. **GitHub Pages deploy stuck in infinite "deployment_queued" loop** — root cause was repo **Settings → Pages → Source** still set to "Deploy from a branch" instead of **"GitHub Actions"**. Fixed by switching that dropdown; deploy then succeeded.
6. **git/GitHub Desktop confusion (multiple rounds)** — user is a first-time git/GitHub user, working entirely through **GitHub Desktop** (not the command line) plus the Supabase web dashboard (also not the CLI). Notable resolved issues: cloning the GitHub repo into a fresh *empty* folder instead of linking the real local project folder (had to delete-and-recreate the GitHub repo empty, then use "Add Local Repository" pointing at the real folder); "repository does not seem to exist" push failures traced to the repo not yet existing under the `thiennhatgroup` org.

## Current blocking issue (unresolved — pick up here)

Login to the live site fails with the generic Vietnamese message **"Email hoặc mã PIN không đúng"** for the admin account:
- Email: `vriens.gpt@gmail.com`
- Auth user UUID (confirmed via `select id, email from auth.users ...`): `d9fc8134-f8ab-4f62-a107-90a77bab2064`
- A matching `profiles` row was inserted with `role = 'Admin'`, `status = 'Hoạt động'` — this insert succeeded ("Success").
- Despite that, login fails — meaning most likely either (a) the Auth password on this account doesn't actually equal `tn-pin::<the PIN the user is typing>` (possibly set during an earlier confused attempt with a different PIN, or never actually set with the right prefix), or (b) the account's email isn't confirmed (Authentication → Users → check the **Confirmed** column for this row).

**Last instructions given, not yet confirmed successful:**
1. In Supabase dashboard → Authentication → Users → find `vriens.gpt@gmail.com` → check **Confirmed** column has a real date (not blank).
2. Use the row's **⋯** menu → find the option to directly set a new password (not the email-link reset) → set it to `tn-pin::9999` (or any known test PIN) → save.
3. Try logging in again with email + `9999`.
4. If it still fails, open browser DevTools (Console + Network tabs) during the login attempt and read the *actual* error Supabase Auth returns (e.g. `invalid_credentials`, `email_not_confirmed`, etc.) rather than the app's generic message — this pinpoints the real cause immediately.

This is the very next thing to debug in the new chat.

## Style / working notes for whoever picks this up

- **User is a genuine beginner** with git, GitHub, and the terminal. Prefers GitHub Desktop over command-line git. Needs every UI step spelled out explicitly (exact button labels, exact menu paths) — abstract instructions like "push your changes" do not land; needs "open GitHub Desktop, click X, then Y."
- **User explicitly asked for concise, direct responses** — avoid over-explaining once something is confirmed working.
- All SQL changes should be re-validated for Postgres syntax before declaring them fixed — no live Postgres instance is available in the assistant's sandbox (aarch64, no root), so `pglast` (`pip install pglast --break-system-packages`) was used for `parse_sql`/`parse_plpgsql`-level validation. This same approach should be used for any further schema changes before asking the user to re-deploy.
- Deploys are 100% GitHub-driven: any SQL migration change → commit via GitHub Desktop → push → GitHub Actions runs `supabase db push` (either automatically if the change touched `supabase/migrations/**`, or manually via Actions tab → "Deploy Supabase migrations" → Run workflow). Any frontend change (`public/`) → same push → "Deploy frontend to GitHub Pages" action runs automatically.
- `SUPABASE_SETUP.md` in the repo has been kept up to date step-by-step throughout this conversation and is the canonical, detailed, beginner-safe reference for the whole setup (sections 1–12, including a very detailed section 6 for git/GitHub Desktop and section 8 for user/role management). Read it before re-explaining any setup step from scratch.
