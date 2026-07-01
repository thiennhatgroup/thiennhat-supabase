-- ============================================================================
-- 0017_payment_requests.sql  (Redesign Đợt B)
-- Đề xuất thanh toán = a payment-request DOCUMENT with its own approval state,
-- separate from `payments` (the actual cash disbursement). Implements the
-- workflow: 15h kế toán lập đề xuất TT (gom khoản đến hạn) -> 16h lãnh đạo
-- duyệt -> kế toán mới đi tiền.
--
-- Hybrid line model (đã chốt): a line either links to an approved AP obligation
-- (debts.id) OR is free-entered (điện, vận hành...) and then must carry a
-- justification. Fields mirror the attached spreadsheet: NCC, Kế hoạch,
-- Đề xuất thanh toán, Nội dung, Hình thức TT, Tình trạng hồ sơ.
-- ============================================================================

create table if not exists payment_requests (
  id uuid primary key default gen_random_uuid(),
  ma_de_xuat_tt text unique not null,
  ngay date not null default current_date,
  nguoi_lap uuid references profiles (id),
  trang_thai text not null default 'Chờ duyệt'
    check (trang_thai in ('Nháp','Chờ duyệt','Đã duyệt','Từ chối','Đã chi')),
  ghi_chu text,
  nguoi_duyet uuid references profiles (id),
  approved_at timestamptz,
  ly_do_tu_choi text,
  executed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_payreq_status on payment_requests (trang_thai);

create table if not exists payment_request_lines (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references payment_requests (id) on delete cascade,
  debt_id uuid references debts (id),           -- nối khoản công nợ đã duyệt (có thể null = dòng tự nhập)
  doi_tuong_id uuid references doi_tuong (id),
  ncc text not null,                            -- tên NCC hiển thị
  ke_hoach numeric not null default 0,          -- Kế hoạch (số theo kế hoạch chi)
  so_tien numeric not null check (so_tien > 0), -- Đề xuất thanh toán
  noi_dung text,
  hinh_thuc_tt text not null default 'CK'
    check (hinh_thuc_tt in ('CK','Tiền mặt')),
  tinh_trang_ho_so text,
  giai_trinh text,                              -- bắt buộc khi dòng không nối công nợ
  created_at timestamptz not null default now()
);
create index if not exists idx_payreq_lines_req on payment_request_lines (request_id);
create index if not exists idx_payreq_lines_debt on payment_request_lines (debt_id);

create or replace trigger trg_payreq_updated
  before update on payment_requests for each row execute function set_updated_at();

alter table payment_requests enable row level security;
alter table payment_request_lines enable row level security;
revoke all on payment_requests from anon, authenticated;
revoke all on payment_request_lines from anon, authenticated;

insert into role_permissions (role, permission) values
  ('KeToanCongNo', 'payment:request'),
  ('KeToanCongNo', 'payment:execute'),
  ('LanhDao',      'payment:approve')
on conflict (role, permission) do nothing;
