# Thiên Nhật — NVL mua hàng / công nợ (Supabase edition)

Supabase-hosted port of the original Google Apps Script + Google Sheets app (`webapp.gs` / `Index.html`). Same roles, same approval workflow, same FIFO payment-settlement math — running on Postgres instead of a spreadsheet.

**New here? Start with [`SUPABASE_SETUP.md`](./SUPABASE_SETUP.md)** — a full beginner walkthrough from "create a Supabase project" to "my team is using the live site."

## Stack

- **Database + Auth + business logic**: [Supabase](https://supabase.com) (Postgres, Row Level Security, SQL functions called via RPC)
- **Frontend**: a single static HTML page (`public/index.html`), hosted for free on GitHub Pages (or Vercel/Netlify)
- **Deployment**: push to GitHub → GitHub Actions publish the frontend automatically; database migrations can be applied by hand (SQL Editor) or automatically via a second GitHub Action

## Repo layout

```text
.
├── SUPABASE_SETUP.md          # beginner setup guide — read this first
├── supabase/
│   ├── migrations/             # run in order 0001 -> 0010
│   ├── after_setup_create_admin.sql
│   └── config.toml
├── public/
│   ├── index.html               # entire frontend, one file
│   └── config.js                # your Supabase URL + anon key go here
└── .github/workflows/           # GitHub Pages + optional DB auto-deploy
```

## Core workflow (unchanged from the original spreadsheet app)

1. **Báo giá NCC** — compare/record supplier price quotes for a material.
2. **Tạo đề xuất** — raise a purchase/payment proposal.
3. **Duyệt đề xuất** — a manager approves or rejects it; approval creates the real debt (`công nợ`) rows.
4. **Nhận hàng** — record actual received quantity against a debt code.
5. **Thanh toán** — record a payment, either against one debt code or FIFO across a whole supplier (oldest due date first).
6. **Dashboard công nợ** — AP/AR summary per counterparty, netted.
7. **Tất toán** — preview then confirm settling fully-paid rows (archived, never deleted).

## What changed vs. the Apps Script version

Two adaptations were necessary because there's no spreadsheet underneath anymore — everything else (roles, permissions, the FIFO settlement rule, the AP/AR netting logic) is identical. See section 10 of `SUPABASE_SETUP.md` for details.

- Settling a debt sets `is_archived = true` instead of moving the row to another sheet.
- The old AppSheet → Google Sheets price-quote sync became a plain "Nhập báo giá mới" form that writes straight into `price_quotes`.

## Roles

| Role | Meaning | Permissions |
| --- | --- | --- |
| `NhanVienMuaHang` | Purchasing staff | quote:read, quote:sync, proposal:create, proposal:submit, receipt:update, recent:read, dashboard:read, catalog:read/create, print:purchasing |
| `TruongPhong` | Department head | quote:read, oversight:read, recent:read, dashboard:read |
| `KeToanCongNo` | AP accountant | quote:read, receipt:review, congno:confirm, payment:request/read/adjust, settlement:preview/confirm, oversight:read/cancel, recent:read, dashboard:read |
| `ThuQuy` | Cashier | payment:execute, receipt:review |
| `ChuTich` / `TongGiamDoc` | Leadership | proposal/payment approvals as routed, quote:read, recent:read, dashboard:read, leaderdash:read |
| `Admin` | Administrator | user:manage, department:manage |
