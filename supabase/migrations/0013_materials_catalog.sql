-- ============================================================================
-- 0013_materials_catalog.sql
-- Codify master data for accurate statistics:
--   * materials: add ma_vat_tu (stable code, auto 'VT-000x' but editable),
--     nhom (product group), trang_thai, updated_at.
--   * doi_tuong: add moq (minimum order qty), sdt (phone) for a fuller profile.
--   * permissions: catalog:read (all working roles) and catalog:manage
--     (TruongPhong; Admin bypasses via has_permission).
-- Backfills existing 21 materials with a code and a best-guess group.
-- Safe / idempotent: add-column guards, on-conflict permission insert.
-- ============================================================================

-- ---- materials: new columns -------------------------------------------------
alter table materials add column if not exists ma_vat_tu  text;
alter table materials add column if not exists nhom       text;
alter table materials add column if not exists trang_thai text not null default 'Hoạt động';
alter table materials add column if not exists updated_at timestamptz not null default now();

-- Sequence that feeds the auto material code. Start after any codes that may
-- already exist so we never collide.
create sequence if not exists seq_vat_tu;

create or replace function next_material_code() returns text
language sql as $$
  select 'VT-' || lpad(nextval('seq_vat_tu')::text, 4, '0');
$$;

-- Backfill codes for rows that don't have one yet (ordered by name for stable,
-- predictable numbering), then classify into the 6 standard groups.
do $$
declare
  r record;
begin
  for r in select id from materials where ma_vat_tu is null order by ten loop
    update materials set ma_vat_tu = next_material_code() where id = r.id;
  end loop;
end $$;

update materials set nhom = case
    when ten ilike '%vận chuyển%'                                             then 'Vật tư phụ tùng sửa chữa'
    when ten ilike '%nhũ tương%' or ten ilike '%nhựa đường%' or ten ilike '%nhũ%' or ten ilike '%MC 70%' or ten ilike '%MC70%'
                                                                              then 'Nhựa đường & nhũ tương'
    when ten ilike '%xi măng%'                                                then 'Xi măng'
    when ten ilike '%bột đá%' or ten ilike '%cát%' or ten ilike '%đá%' or ten ilike '%cốt liệu%'
                                                                              then 'Đá & cát'
    when ten ilike '%diesel%' or ten ilike '%DO 0%' or ten ilike '%dầu do%'   then 'Dầu diesel'
    when ten ilike '%dầu%' or ten ilike '%mỡ%' or ten ilike '%HFO%' or ten ilike '%thủy lực%' or ten ilike '%truyền nhiệt%'
                                                                              then 'Dầu & mỡ chuyên dụng'
    else 'Vật tư phụ tùng sửa chữa'
  end
where nhom is null;

-- Make the code the default for any future material (e.g. rows created by
-- ensure_material() when a buyer types a brand-new item), and enforce
-- uniqueness. Done after backfill so the default never fires on old rows.
alter table materials alter column ma_vat_tu set default next_material_code();
alter table materials alter column ma_vat_tu set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'uq_materials_ma_vat_tu') then
    alter table materials add constraint uq_materials_ma_vat_tu unique (ma_vat_tu);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'chk_materials_trang_thai') then
    alter table materials add constraint chk_materials_trang_thai
      check (trang_thai in ('Hoạt động','Ngừng'));
  end if;
end $$;

create or replace trigger trg_materials_updated
  before update on materials for each row execute function set_updated_at();

-- ---- doi_tuong: fuller supplier profile -------------------------------------
alter table doi_tuong add column if not exists moq text;
alter table doi_tuong add column if not exists sdt text;

-- ---- permissions ------------------------------------------------------------
insert into role_permissions (role, permission) values
  ('NhanVienMuaHang', 'catalog:read'),
  ('TruongPhong',     'catalog:read'),
  ('TruongPhong',     'catalog:manage'),
  ('KeToanCongNo',    'catalog:read'),
  ('LanhDao',         'catalog:read')
on conflict (role, permission) do nothing;
