-- ============================================================================
-- 0001_schema.sql
-- Thiên Nhật — NVL mua hàng / công nợ (Supabase port)
--
-- This mirrors the legacy Google Apps Script workbook 1:1 in meaning:
--   CAI_DAT_QUYEN         -> profiles + role_permissions
--   DM_DOI_TUONG          -> doi_tuong
--   DANH_MUC / vat tu list -> materials
--   DATA_GOC (bao gia)    -> price_quotes
--   WEB_DE_XUAT_HEADER    -> proposals
--   WEB_DE_XUAT_LINES     -> proposal_lines
--   05_CONG_NO_NCC        -> debts (+ is_archived flag instead of "cut row to
--                            DU_LIEU_CONG_NO sheet" — see note below)
--   DB_THANH_TOAN         -> payments (+ payment_allocations for traceability,
--                            an addition not present in the sheet, kept purely
--                            for audit — it does not change any computed
--                            business number)
--   WEB_AUDIT_LOG         -> audit_log
--   APP_CONFIG            -> app_config
--
-- Design note on "archive": the spreadsheet version physically cuts fully
-- settled rows out of 05_CONG_NO_NCC and pastes them into DU_LIEU_CONG_NO so
-- the working sheet stays short. A relational database does not need that
-- trick — we keep every debt row in one table and flip `is_archived` to true
-- when it is fully settled. Every screen that used to read "the open rows"
-- now simply filters `is_archived = false`; every screen that used to read
-- the archive sheet filters `is_archived = true`. The business rule (FIFO
-- netting per NCC, only fully-paid lots get taken out of the working view)
-- is preserved exactly; only the storage mechanism changed.
-- ============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists unaccent;   -- Vietnamese-diacritic-insensitive matching

-- ----------------------------------------------------------------------------
-- Reference / master data
-- ----------------------------------------------------------------------------

create table if not exists app_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text unique not null,
  name text not null,
  role text not null check (role in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','LanhDao','Admin')),
  status text not null default 'Hoạt động' check (status in ('Hoạt động','Ngừng')),
  scope_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table profiles is 'Mirrors CAI_DAT_QUYEN. One row per Supabase Auth user, keyed by auth.users.id.';

create table if not exists role_permissions (
  role text not null,
  permission text not null,
  primary key (role, permission)
);
comment on table role_permissions is 'Mirrors WEB_ROLE_PERMISSIONS in webapp.gs. Admin bypasses this table entirely (treated as "*").';

create table if not exists doi_tuong (
  id uuid primary key default gen_random_uuid(),
  ma_doi_tuong text unique not null,
  ten_doi_tuong text not null,
  loai text not null default 'NCC',
  mst text,
  dia_chi text,
  contact text,
  dieu_khoan_tt_mac_dinh text,
  trang_thai text not null default 'Hoạt động',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table doi_tuong is 'Mirrors DM_DOI_TUONG (counterparties / suppliers).';

create table if not exists materials (
  id uuid primary key default gen_random_uuid(),
  ten text unique not null,
  dvt text,
  created_at timestamptz not null default now()
);
comment on table materials is 'Mirrors the "vật tư hàng hoá" dropdown sourced from DANH_MUC / 00_THU_VIEN_NCC.';

-- ----------------------------------------------------------------------------
-- Price quotes (DATA_GOC)
-- ----------------------------------------------------------------------------

create table if not exists price_quotes (
  id uuid primary key default gen_random_uuid(),
  ngay date not null default current_date,
  ma text,
  ncc text not null,
  mat_hang text not null,
  gia numeric not null check (gia >= 0),
  vat_status text not null default 'Chưa VAT' check (vat_status in ('Chưa VAT','Đã gồm VAT')),
  dvt text,
  de_xuat text not null default 'Không' check (de_xuat in ('Có','Không')),
  ghi_chu text,
  nguon text not null default 'Manual',
  created_by uuid references profiles (id),
  created_at timestamptz not null default now()
);
create index if not exists idx_price_quotes_item on price_quotes (mat_hang);
create index if not exists idx_price_quotes_item_date on price_quotes (mat_hang, ngay desc);
comment on table price_quotes is 'Mirrors DATA_GOC price-quote log used by 01_SO_SANH_NCC / 02_BIEN_DONG / quote dashboard.';

-- ----------------------------------------------------------------------------
-- Proposals (WEB_DE_XUAT_HEADER / WEB_DE_XUAT_LINES)
-- ----------------------------------------------------------------------------

create table if not exists proposals (
  id uuid primary key default gen_random_uuid(),
  ma_de_xuat text unique not null,
  ngay_de_xuat date not null default current_date,
  nguoi_de_nghi text,
  doi_tuong_id uuid references doi_tuong (id),
  ten_doi_tuong text,
  noi_dung text,
  dieu_khoan_tt text,
  trang_thai text not null default 'Nháp' check (trang_thai in ('Nháp','Chờ duyệt','Đã duyệt','Từ chối')),
  nguoi_tao uuid references profiles (id),
  created_at timestamptz not null default now(),
  nguoi_duyet uuid references profiles (id),
  approved_at timestamptz,
  ghi_chu text
);
create index if not exists idx_proposals_status on proposals (trang_thai);
create index if not exists idx_proposals_doi_tuong on proposals (doi_tuong_id);

create table if not exists proposal_lines (
  id uuid primary key default gen_random_uuid(),
  ma_line text unique not null,
  proposal_id uuid not null references proposals (id) on delete cascade,
  debt_id uuid, -- filled in after approval, references debts(id); FK added after debts table exists
  mat_hang text not null,
  sl_dat numeric not null check (sl_dat > 0),
  don_gia_chua_vat numeric not null check (don_gia_chua_vat >= 0),
  vat_rate numeric not null default 0.08,
  thanh_tien_sau_vat numeric,
  ghi_chu text,
  trang_thai text not null default 'Nháp'
);
create index if not exists idx_proposal_lines_proposal on proposal_lines (proposal_id);

-- ----------------------------------------------------------------------------
-- Debts / accounts payable (05_CONG_NO_NCC)
-- ----------------------------------------------------------------------------

create table if not exists debts (
  id uuid primary key default gen_random_uuid(),
  ma_cn text unique not null,
  ngay_de_xuat date,
  ngay_duyet date,
  doi_tuong_id uuid references doi_tuong (id),
  ten_doi_tuong text,
  loai_cong_no text not null default 'AP' check (loai_cong_no in ('AP','TamUng')),
  proposal_id uuid references proposals (id),
  ma_lo_hang text,
  ma_chung_tu text,
  mat_hang text not null,
  sl_dat numeric,
  sl_thuc_nhan numeric,
  don_gia numeric not null default 0,
  vat_rate numeric not null default 0,
  dieu_khoan_tt text,
  ngay_nhan date,
  han_thanh_toan date,
  ngay_tt_cuoi date,
  da_thanh_toan numeric not null default 0 check (da_thanh_toan >= 0),
  ghi_chu text,
  nguon_tao text not null default 'WebApp',
  is_archived boolean not null default false,
  archived_at timestamptz,
  archived_by uuid references profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_debts_doi_tuong on debts (doi_tuong_id);
create index if not exists idx_debts_archived on debts (is_archived);
create index if not exists idx_debts_ma_cn on debts (ma_cn);
comment on table debts is 'Mirrors 05_CONG_NO_NCC. is_archived=true is the equivalent of a row having been cut into DU_LIEU_CONG_NO.';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fk_proposal_lines_debt'
  ) then
    alter table proposal_lines
      add constraint fk_proposal_lines_debt foreign key (debt_id) references debts (id);
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- Payments (DB_THANH_TOAN)
-- ----------------------------------------------------------------------------

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  ma_thanh_toan text unique not null,
  ngay_thanh_toan date not null default current_date,
  doi_tuong_id uuid references doi_tuong (id),
  ten_doi_tuong text,
  so_tien numeric not null check (so_tien > 0),
  phan_bo_mode text not null default 'FIFO' check (phan_bo_mode in ('FIFO','MA_CN')),
  ma_cn text,
  chung_tu text,
  ghi_chu text,
  nguoi_nhap uuid references profiles (id),
  created_at timestamptz not null default now(),
  trang_thai text not null default 'Đã ghi nhận'
);
create index if not exists idx_payments_doi_tuong on payments (doi_tuong_id);

create table if not exists payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references payments (id) on delete cascade,
  debt_id uuid references debts (id),
  ma_cn text,
  so_tien_phan_bo numeric not null,
  created_at timestamptz not null default now()
);
comment on table payment_allocations is 'Extra ledger (not in the original sheet) purely so a payment''s FIFO split across lots is auditable. Does not change any computed business figure.';

-- ----------------------------------------------------------------------------
-- Audit log (WEB_AUDIT_LOG)
-- ----------------------------------------------------------------------------

create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  log_id text unique not null,
  time timestamptz not null default now(),
  actor_id uuid references profiles (id),
  actor_email text,
  actor_name text,
  role text,
  action text not null,
  entity_type text not null,
  entity_id text,
  before_json jsonb,
  after_json jsonb,
  result text not null default 'OK',
  message text
);
create index if not exists idx_audit_entity on audit_log (entity_type, entity_id);

-- ----------------------------------------------------------------------------
-- Code sequence helper (mirrors nextWebId_ in webapp.gs: PREFIX-YYYYMMDD-NNN)
-- ----------------------------------------------------------------------------

create table if not exists code_counters (
  prefix text not null,
  day date not null,
  seq int not null default 0,
  primary key (prefix, day)
);

create or replace function next_code(p_prefix text) returns text
language plpgsql as $$
declare
  v_seq int;
  v_day date := current_date;
begin
  insert into code_counters (prefix, day, seq) values (p_prefix, v_day, 1)
  on conflict (prefix, day) do update set seq = code_counters.seq + 1
  returning seq into v_seq;
  return p_prefix || '-' || to_char(v_day, 'YYYYMMDD') || '-' || lpad(v_seq::text, 3, '0');
end;
$$;

-- ----------------------------------------------------------------------------
-- Vietnamese-diacritic-insensitive text normalizer (mirrors normalizeHeaderKey_/textKey_)
-- ----------------------------------------------------------------------------

create or replace function normalize_text(p_text text) returns text
language sql immutable as $$
  select trim(regexp_replace(lower(unaccent(replace(coalesce(p_text, ''), 'đ', 'd'))), '[^a-z0-9]+', ' ', 'g'));
$$;

-- ----------------------------------------------------------------------------
-- updated_at triggers
-- ----------------------------------------------------------------------------

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace trigger trg_profiles_updated before update on profiles for each row execute function set_updated_at();
create or replace trigger trg_doi_tuong_updated before update on doi_tuong for each row execute function set_updated_at();
create or replace trigger trg_debts_updated before update on debts for each row execute function set_updated_at();
