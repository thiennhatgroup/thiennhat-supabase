-- ============================================================================
-- 0020_groups_bank_acceptance.sql
--  * material_groups: nhóm hàng trở thành dữ liệu động (thêm/sửa được), thay
--    cho mảng cứng trong RPC. Seed 6 nhóm chuẩn.
--  * doi_tuong: thêm số tài khoản + chi nhánh ngân hàng (phục vụ chi tiền/UNC).
--  * debts: thêm trường nghiệm thu (hồ sơ đầy đủ, ai nghiệm thu, khi nào) —
--    bước nghiệm thu khối lượng/chất lượng thực nhận là cơ sở để NCC lập hóa
--    đơn VAT và để chốt về công nợ.
-- ============================================================================

create table if not exists material_groups (
  id uuid primary key default gen_random_uuid(),
  ten text unique not null,
  stt int not null default 100,
  created_at timestamptz not null default now()
);

insert into material_groups (ten, stt) values
  ('Nhựa đường & nhũ tương', 1),
  ('Đá & cát', 2),
  ('Xi măng', 3),
  ('Dầu diesel', 4),
  ('Dầu & mỡ chuyên dụng', 5),
  ('Vật tư phụ tùng sửa chữa', 6)
on conflict (ten) do nothing;

alter table doi_tuong add column if not exists so_tk_ngan_hang text;
alter table doi_tuong add column if not exists chi_nhanh_ngan_hang text;

alter table debts add column if not exists ho_so_day_du boolean not null default false;
alter table debts add column if not exists nghiem_thu_at timestamptz;
alter table debts add column if not exists nghiem_thu_by uuid references profiles (id);

alter table material_groups enable row level security;
revoke all on material_groups from anon, authenticated;
