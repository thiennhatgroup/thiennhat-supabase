# Thiên Nhật — Mua hàng & Công nợ (bản Supabase)

A from-scratch beginner setup guide. No prior Supabase/GitHub experience assumed.

This project replaces the original Google Apps Script + Google Sheets app with:

- **Database + Auth + business logic** → Supabase (Postgres)
- **Frontend** → one static HTML page, hosted for free on **GitHub Pages** (or Vercel/Netlify if you prefer)

The two pieces talk to each other over the internet — there is nothing to install on your computer to run this in production. You only need a browser and (optionally) a phone.

---

## 0. What you'll end up with

- A Supabase project holding all your data (customers/suppliers, price quotes, proposals, debts, payments, audit log).
- A public URL (like `https://yourname.github.io/thiennhat-supabase/`) that your team opens to use the app.
- A GitHub repo that is the single source of truth — push a change, it goes live.

---

## 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com) and sign in (you said you already have an account).
2. Click **New project**.
3. Pick an organization, give the project a name (e.g. `thiennhat`), set a strong **database password** — **save this password somewhere**, you'll need it later for the GitHub Action.
4. Pick the region closest to your users (e.g. Singapore) and click **Create new project**. Wait ~2 minutes while it provisions.

---

## 2. Get your API keys

1. In the Supabase dashboard, open your project.
2. Go to **Project Settings** (gear icon) → **API**.
3. Copy two values, you'll paste them in step 5:
   - **Project URL** — looks like `https://abcdefgh.supabase.co`
   - **anon public** key — a long string starting with `eyJ...`

These are safe to put in a public GitHub repo / public website. They do **not** grant access to your data — every table has Row Level Security turned on with zero policies, so the anon key can only call the specific RPC functions this project defines (see `supabase/migrations/0002_rls.sql`).

---

## 3. Run the database migrations

You have two options. **Do Option A first** — it always works and takes 10 minutes. Set up Option B later once you're comfortable.

### Option A — paste into the SQL Editor (recommended to start)

1. In the Supabase dashboard, open **SQL Editor** (left sidebar).
2. Click **New query**.
3. Open each file in `supabase/migrations/` **in this exact numeric order** and paste its full contents into the editor, then click **Run**, one file at a time:
   1. `0001_schema.sql`
   2. `0002_rls.sql`
   3. `0003_seed_reference.sql`
   4. `0004_permissions.sql`
   5. `0005_debts_view.sql`
   6. `0006_rpc_bootstrap_quotes.sql`
   7. `0007_rpc_proposals.sql`
   8. `0008_rpc_receipts_payments.sql`
   9. `0009_rpc_dashboard_settlement.sql`
   10. `0010_rpc_recent.sql`
4. Each one should say "Success. No rows returned" (or similar). If one fails, stop and re-check you ran the previous ones first — most later files depend on tables/functions created earlier.

That's it — your database now has every table, security rule, and business-logic function the app needs.

### Option B — automatic deploy from GitHub (do this after Option A works)

This repo already includes `.github/workflows/deploy-db.yml`, which runs `supabase db push` every time you push a change under `supabase/migrations/` to your `main` branch.

To turn it on:

1. Push this repo to GitHub (see section 6 below) if you haven't already.
2. Get a Supabase **access token**: [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens) → **Generate new token**.
3. Find your **project ref**: it's the subdomain of your Project URL, e.g. if your URL is `https://abcdefgh.supabase.co`, the ref is `abcdefgh`.
4. In your GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**. Add these three:
   - `SUPABASE_ACCESS_TOKEN` = the token from step 2
   - `SUPABASE_PROJECT_REF` = the ref from step 3
   - `SUPABASE_DB_PASSWORD` = the database password you set in step 1
5. Also edit `supabase/config.toml` and replace `REPLACE_WITH_YOUR_PROJECT_REF` with your real project ref, then commit.
6. From now on, editing anything under `supabase/migrations/` and pushing to `main` will automatically apply it to your live database.

If you skip Option B entirely, that's fine — Option A works forever, you'll just paste future SQL changes by hand.

---

## 4. Turn on email/password login

1. Supabase dashboard → **Authentication → Providers**. Make sure **Email** is enabled (it is by default).
2. Authentication → **Sign In / Providers → Email** settings: for an internal company tool, you can turn **off** "Confirm email" so staff can log in immediately after you create their account (Authentication → Settings → uncheck "Enable email confirmations"). If you leave it on, you must confirm each new user's email in the dashboard before they can log in.
3. Leave "Minimum password length" at its default (6) — the app already handles short PINs safely (see next section).

### Why the login uses "PIN" but Supabase needs a "password"

Supabase Auth only understands email + password, not a raw 4–6 digit PIN. The frontend (`public/index.html`) quietly turns your PIN into a real password by prefixing it: a PIN of `1234` becomes the password `tn-pin::1234`. This is the same trick the sibling Firebase version of this app uses, so the login experience (type email + short PIN) is identical for your staff — they never see or type the prefix.

---

## 5. Configure the frontend

1. Open `public/config.js` in this repo.
2. Replace the two placeholders with the values from step 2:

   ```js
   window.APP_CONFIG = {
     supabaseUrl: "https://abcdefgh.supabase.co",
     supabaseAnonKey: "eyJ...your-anon-key...",
   };
   ```

3. Save the file. That's the only code change required per deployment.

---

## 6. Push this repo to GitHub (step-by-step for total beginners)

This is the step where most people get stuck, so it's spelled out in full. Do it in order — don't skip ahead.

### 6.1 Open a terminal

- **Mac**: press `Cmd + Space`, type `Terminal`, press Enter.
- **Windows**: click Start, type `PowerShell`, press Enter.

A window with a blinking cursor opens. This is where you'll type every command below (type the command, press Enter, wait for it to finish before typing the next one).

### 6.2 Check that git is installed

Type:

```bash
git --version
```

- If you see something like `git version 2.43.0` → skip to 6.3.
- If you see `git: command not found` (Mac) or `'git' is not recognized...` (Windows) → git isn't installed yet:
  - **Mac**: type `xcode-select --install`, click **Install** in the popup, wait for it to finish, then try `git --version` again.
  - **Windows**: download and run the installer from [git-scm.com/downloads](https://git-scm.com/downloads) — click Next through every screen with the defaults, then reopen PowerShell and try again.

### 6.3 Tell git who you are (one-time only, ever)

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

Skipping this is the single most common cause of errors in the next steps (you'll see `Please tell me who you are` when you try to commit). Use any name/email — it's just a label on your commits, it doesn't need to match your GitHub account.

### 6.4 Move into the project folder

This folder's full name has spaces and Vietnamese accents in it, which trips up a lot of copy-pasted `cd` commands. The safest way:

1. Type `cd ` (with a trailing space) into the terminal — **don't press Enter yet**.
2. Open Finder (Mac) or File Explorer (Windows), find the `thiennhat-supabase` folder inside your `Phần mềm duyệt đề xuất mua hàng - theo dõi công nợ` project folder.
3. **Drag that folder icon directly into the terminal window.** The terminal will automatically type out the full, correctly escaped path for you.
4. Now press Enter.

Verify you're in the right place:

```bash
ls
```

(Mac/Linux) or `dir` (Windows) — you should see `README.md`, `SUPABASE_SETUP.md`, `public`, `supabase` listed. If you don't see those, you're in the wrong folder — repeat step 6.4.

### 6.5 Turn the folder into a git repository

Now, one command at a time:

```bash
git init
```

```bash
git add .
```

```bash
git commit -m "Initial Supabase port of Thien Nhat NVL app"
```

The `commit` command should print a summary line like `[main (root-commit) abc1234] Initial Supabase port...` with a file count. That means it worked.

### 6.6 Create the (empty) repository on GitHub.com

1. Go to [github.com](https://github.com) and log in.
2. Click the **+** icon top-right → **New repository**.
3. Name it (e.g. `thiennhat-supabase`).
4. **Do not** check "Add a README", "Add .gitignore", or "Choose a license" — leave the repo completely empty. (If any of those are checked, the push in 6.7 will fail with "fetch first" / non-fast-forward errors.)
5. Click **Create repository**. GitHub shows you a page with a URL like `https://github.com/YOUR_USERNAME/thiennhat-supabase.git` — keep this page open.

### 6.7 Connect and push

Back in the terminal (still inside the project folder):

```bash
git remote add origin https://github.com/YOUR_USERNAME/thiennhat-supabase.git
git branch -M main
git push -u origin main
```

(Replace the URL with the exact one GitHub showed you in 6.6.)

**This is where it will likely ask you to log in — and this is the #1 beginner blocker**, because GitHub no longer accepts your regular account password here. You need a **Personal Access Token** instead:

1. On GitHub.com, click your profile picture (top-right) → **Settings**.
2. Scroll to the bottom of the left sidebar → **Developer settings**.
3. **Personal access tokens → Tokens (classic)** → **Generate new token (classic)**.
4. Give it any name, set an expiration (90 days is fine), check the box next to **repo**, then **Generate token**.
5. **Copy the token immediately** (it looks like `ghp_xxxxxxxxxxxx`) — GitHub only shows it once.
6. When the terminal prompts for a username, type your GitHub username. When it prompts for a password, **paste the token** (not your real password) — pasted text won't show on screen, that's normal, just press Enter after pasting.

If you'd rather avoid the terminal entirely for this part, see the GUI alternative below.

### GUI alternative: GitHub Desktop (no commands at all)

If typing commands isn't for you, skip 6.1–6.7 entirely and use this instead:

1. Download and install [GitHub Desktop](https://desktop.github.com/).
2. Open it, sign in with your GitHub account (this handles login/tokens for you automatically).
3. **File → Add local repository** → browse to and select the `thiennhat-supabase` folder.
4. It will offer to **create a repository** here if one doesn't exist yet — click that.
5. Type a commit summary (e.g. "Initial Supabase port") in the bottom-left box → **Commit to main**.
6. Click **Publish repository** in the top bar → make sure it's **not** set to private if you want free GitHub Pages, then **Publish**.

That's equivalent to all of 6.1–6.7 in a few clicks.

### Common errors and exact fixes

| Error message | What it means | Fix |
| --- | --- | --- |
| `git: command not found` / `'git' is not recognized` | Git isn't installed | Do step 6.2 |
| `Please tell me who you are` | Never set your git identity | Do step 6.3, then re-run `git commit` |
| `fatal: not a git repository (or any of the parent directories): .git` | You're not inside the project folder, or ran `git add`/`commit` before `git init` | Re-do step 6.4, confirm with `ls`/`dir`, then step 6.5 again |
| `nothing to commit, working tree clean` after `git commit` | You already committed everything — this is fine, not an error, move on to 6.6 | — |
| `remote origin already exists` | You ran `git remote add origin` twice | Run `git remote remove origin`, then re-run the `git remote add origin ...` line |
| `Support for password authentication was removed` / `fatal: Authentication failed` | You typed your real GitHub password instead of a token | Generate a Personal Access Token (step 6.7) and paste that as the password instead |
| `fatal: repository 'https://github.com/...' not found` | The URL is mistyped, or the repo name/username doesn't match exactly | Re-copy the URL from the GitHub page in step 6.6 |
| `error: src refspec main does not match any` | Step 6.5's commit didn't actually happen | Re-check `git commit` printed a summary line; re-run 6.5 |
| `! [rejected] main -> main (fetch first)` | You checked "Add a README" when creating the GitHub repo, so it's not empty | Delete the repo on GitHub and recreate it with nothing checked (step 6.6), or ask if you want the merge-instead-of-recreate steps |

Still stuck? Paste the **exact error text** you're seeing and which command produced it — that pins down the fix immediately instead of guessing.

---

## 7. Publish the frontend (GitHub Pages)

This repo includes `.github/workflows/deploy-frontend.yml`, which publishes the `public/` folder automatically.

1. On GitHub, open your repo → **Settings → Pages**.
2. Under **Build and deployment → Source**, choose **GitHub Actions**.
3. Push anything to `main` (or go to the **Actions** tab and run "Deploy frontend to GitHub Pages" manually).
4. After it finishes (green check), your app is live at `https://YOUR_USERNAME.github.io/YOUR_REPO_NAME/`.

**Alternative hosts:** if you'd rather use Vercel, Netlify, or Cloudflare Pages instead of GitHub Pages, just connect your GitHub repo to any of them and set the "root directory" / "publish directory" to `public/` — no build step is needed, it's plain HTML/CSS/JS.

---

## 8. Create your first user (Admin)

1. Supabase dashboard → **Authentication → Users → Add user**.
   - Email: your work email
   - Password: `tn-pin::` followed by whatever PIN you want to remember, e.g. `tn-pin::123456`
   - Check **Auto Confirm User** so you don't need to click an email link.
2. Open `supabase/after_setup_create_admin.sql` in this repo, and run it in the SQL Editor:
   - First query shows you the `id` (a UUID) Supabase just gave your new user.
   - Paste that id into the `insert into profiles (...)` statement, along with your email/name, and set `role` to `Admin`.
   - Run it.
3. Go to your live site (step 7), log in with your email and the PIN part only (e.g. `123456`, **not** the `tn-pin::` prefix — the app adds that automatically), and you should land on the "Báo giá NCC" screen with every menu item visible (Admin sees everything).

Add more staff the same way — create their Auth user with `tn-pin::<their PIN>`, then add a `profiles` row with the appropriate role:

| Role | Vietnamese meaning | Can do |
| --- | --- | --- |
| `NhanVienMuaHang` | Nhân viên mua hàng | Xem báo giá, tạo/gửi đề xuất, cập nhật nhận hàng |
| `TruongPhong` | Trưởng phòng | Duyệt/từ chối đề xuất |
| `KeToanCongNo` | Kế toán công nợ | Cập nhật nhận hàng, ghi thanh toán, preview/confirm tất toán |
| `LanhDao` | Lãnh đạo | Chỉ xem báo giá + dashboard công nợ |
| `Admin` | Quản trị | Mọi quyền |

---

## 9. Everyday use

Nothing else to install. Staff open the GitHub Pages URL, log in, and use the screens exactly like the original spreadsheet-based app:

1. **Báo giá NCC** — compare supplier prices for a material, log a new quote.
2. **Tạo đề xuất** — sales/purchasing raises a purchase/payment proposal.
3. **Duyệt đề xuất** — a manager approves or rejects it; approving turns it into real debt rows.
4. **Nhận hàng** — record the actual received quantity against a debt code (Mã CN).
5. **Thanh toán** — record a payment, either against one specific debt code or FIFO across the whole supplier (oldest due date first, exactly like the original spreadsheet macro).
6. **Dashboard công nợ** — AP/AR summary per counterparty, net of payments.
7. **Tất toán** — preview then confirm settling fully-paid debt rows (they get archived instead of deleted, so history is never lost).

---

## 10. What changed vs. the original Google Sheets/Apps Script version

This is a faithful port of the business logic in `webapp.gs`/`Index.html` — same roles, same permissions, same FIFO settlement math, same approval workflow. Two things were necessarily adapted because there's no spreadsheet underneath anymore:

- **"Clear tất toán" no longer moves rows to another sheet.** A settled debt row gets `is_archived = true` instead of being cut from `05_CONG_NO_NCC` and pasted into `DU_LIEU_CONG_NO`. Every screen that used to read "the open rows" now reads `is_archived = false`; nothing in the FIFO/netting math changed.
- **AppSheet price-quote sync is gone.** There's no Google Sheets/AppSheet in this stack, so the "Đồng bộ AppSheet" button became a plain "Nhập báo giá mới" form on the Báo giá screen — it writes straight into the `price_quotes` table. If you later want an external system (ERP, a phone form, etc.) to submit quotes automatically, it can call the same `rpc_add_price_quote` function this form uses.

Everything else — roles, permissions, proposal → debt → payment → settlement flow, the exact FIFO ordering rule (oldest due date first, falling back to receive/approve/proposal date), and the AP/AR netting logic — is the same.

---

## 11. Troubleshooting

**"Tài khoản chưa được cấp quyền truy cập hệ thống"** after logging in
→ The Auth user exists but there's no matching row in `profiles` yet, or the `id` doesn't match. Re-check step 8.

**Login says "Email hoặc mã PIN không đúng"**
→ Either the email doesn't exist in Supabase Auth yet, or you typed the PIN without remembering it needs the `tn-pin::` prefix internally — you should type only the PIN itself in the login form; the page adds the prefix for you. Double check the password you set when creating the user in the dashboard actually was `tn-pin::<the same PIN>`.

**"Tài khoản chưa xác nhận email"**
→ Turn off "Confirm email" in Authentication settings (step 4), or click **Confirm email** manually next to that user in Authentication → Users.

**Blank page / "Failed to fetch" in the browser console**
→ `public/config.js` still has the placeholder `REPLACE_ME` values. Fill them in (step 5).

**A screen shows "Vai trò ... không có quyền thực hiện thao tác này"**
→ Working as intended — that user's role doesn't include that permission. Check the role table in section 8, or change their role in `profiles`.

**Dropdowns for "Mặt hàng" / "Đối tượng" are empty**
→ Normal on a brand-new project — nobody has entered any suppliers/materials yet. They get created automatically the first time someone types a new name into any "nhập mới" field (proposal, payment, or the price-quote form).

---

## 12. Project structure

```text
.
├── supabase/
│   ├── config.toml                     # Supabase CLI project link (Option B)
│   ├── after_setup_create_admin.sql     # run once by hand after step 3
│   └── migrations/
│       ├── 0001_schema.sql              # tables, indexes, helpers
│       ├── 0002_rls.sql                 # deny-by-default security
│       ├── 0003_seed_reference.sql      # role permissions, default VAT rate
│       ├── 0004_permissions.sql         # permission checks, audit log, text helpers
│       ├── 0005_debts_view.sql          # computed debt formulas (v_debts)
│       ├── 0006_rpc_bootstrap_quotes.sql# login bootstrap + price-quote dashboard
│       ├── 0007_rpc_proposals.sql       # create/approve/reject proposals
│       ├── 0008_rpc_receipts_payments.sql # receive goods + record payments (FIFO)
│       ├── 0009_rpc_dashboard_settlement.sql # AP/AR dashboard + settlement
│       └── 0010_rpc_recent.sql          # "recent data" side panel on every screen
├── public/
│   ├── index.html                       # the entire frontend (one file)
│   └── config.js                        # your Supabase URL + anon key
└── .github/workflows/
    ├── deploy-db.yml                    # optional: auto-push migrations
    └── deploy-frontend.yml              # publishes public/ to GitHub Pages
```
