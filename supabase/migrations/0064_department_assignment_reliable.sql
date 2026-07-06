-- ============================================================================
-- 0064_department_assignment_reliable.sql
--  Vertical slice 1: Make Department Assignment Reliable.
--   * Departments are Admin-managed and referenced by hidden UUIDs.
--   * Existing bo_phan text remains the visible display/snapshot field.
--   * Purchasing staff and department heads must have a department before use.
--   * Proposal create/update ignores browser boPhan and uses backend state.
--   * Existing text departments are backfilled into the department list.
-- ============================================================================

create table if not exists departments (
  id uuid primary key default gen_random_uuid(),
  ten text unique not null,
  created_at timestamptz not null default now()
);
alter table departments enable row level security;
revoke all on departments from anon, authenticated;

alter table profiles  add column if not exists department_id uuid references departments (id);
alter table proposers add column if not exists department_id uuid references departments (id);
alter table proposals add column if not exists department_id uuid references departments (id);

create index if not exists idx_profiles_department  on profiles (department_id);
create index if not exists idx_proposers_department on proposers (department_id);
create index if not exists idx_proposals_department on proposals (department_id);

-- Backfill the single Admin-managed department list from legacy text fields.
insert into departments (ten)
select distinct trim(bo_phan)
from (
  select bo_phan from profiles
  union all
  select bo_phan from proposers
  union all
  select bo_phan from proposals
) s
where nullif(trim(coalesce(bo_phan, '')), '') is not null
on conflict (ten) do nothing;

update profiles p
set department_id = (
  select d.id from departments d
  where normalize_text(d.ten) = normalize_text(p.bo_phan)
  order by d.created_at, d.ten
  limit 1
)
where p.department_id is null
  and nullif(trim(coalesce(p.bo_phan, '')), '') is not null;

update proposers p
set department_id = (
  select d.id from departments d
  where normalize_text(d.ten) = normalize_text(p.bo_phan)
  order by d.created_at, d.ten
  limit 1
)
where p.department_id is null
  and nullif(trim(coalesce(p.bo_phan, '')), '') is not null;

update proposals p
set department_id = (
  select d.id from departments d
  where normalize_text(d.ten) = normalize_text(p.bo_phan)
  order by d.created_at, d.ten
  limit 1
)
where p.department_id is null
  and nullif(trim(coalesce(p.bo_phan, '')), '') is not null;

-- Keep current profile/proposer display text aligned with the assigned ID.
update profiles p
set bo_phan = d.ten
from departments d
where p.department_id = d.id
  and p.bo_phan is distinct from d.ten;

update proposers p
set bo_phan = d.ten
from departments d
where p.department_id = d.id
  and p.bo_phan is distinct from d.ten;

-- Admin-managed departments --------------------------------------------------
create or replace function rpc_add_department(p_ten text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ten text := nullif(trim(coalesce(p_ten,'')),'');
begin
  v_actor := require_permission('user:manage');
  if v_ten is null then raise exception 'Cần nhập tên bộ phận.'; end if;
  insert into departments (ten) values (v_ten) on conflict (ten) do nothing;
  perform write_audit(v_actor, 'ADD_DEPARTMENT', 'departments', v_ten, null, jsonb_build_object('ten', v_ten), 'OK', '');
  return jsonb_build_object('ok', true, 'departments', (
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'ten', ten) order by ten), '[]'::jsonb)
    from departments
  ));
end; $$;

drop function if exists rpc_add_proposer(text, text);
create or replace function rpc_add_proposer(p_ten text, p_bo_phan text default null, p_department_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ten text := nullif(trim(coalesce(p_ten,'')),'');
  v_department_id uuid := p_department_id;
  v_department_name text := nullif(trim(coalesce(p_bo_phan,'')),'');
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then raise exception 'Cần nhập tên người đề nghị.'; end if;

  if v_department_id is not null then
    select ten into v_department_name from departments where id = v_department_id;
    if v_department_name is null then raise exception 'Bộ phận không tồn tại trong danh mục.'; end if;
  elsif v_department_name is not null then
    select id, ten into v_department_id, v_department_name
    from departments
    where normalize_text(ten) = normalize_text(v_department_name)
    order by created_at, ten
    limit 1;
    if v_department_id is null then raise exception 'Bộ phận "%" chưa có trong danh mục. Hãy thêm bộ phận trước.', p_bo_phan; end if;
  end if;

  insert into proposers (ten, bo_phan, department_id)
  values (v_ten, v_department_name, v_department_id)
  on conflict (ten) do update set bo_phan = excluded.bo_phan, department_id = excluded.department_id;

  return jsonb_build_object('ok', true, 'proposers', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'ten', p.ten, 'departmentId', p.department_id, 'boPhan', coalesce(d.ten, p.bo_phan)
    ) order by p.ten), '[]'::jsonb)
    from proposers p
    left join departments d on d.id = p.department_id
  ));
end; $$;

-- Bootstrap + catalog --------------------------------------------------------
create or replace function rpc_bootstrap() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile profiles;
  v_perms jsonb;
  v_all boolean;
  v_department_name text;
begin
  select * into v_profile from profiles where id = auth.uid();
  if v_profile is null then raise exception 'Tài khoản chưa được cấp quyền truy cập hệ thống. Hãy liên hệ Admin để tạo hồ sơ trong bảng profiles.'; end if;
  if v_profile.status <> 'Hoạt động' then raise exception 'Tài khoản chưa ở trạng thái Hoạt động.'; end if;

  select ten into v_department_name from departments where id = v_profile.department_id;
  v_department_name := coalesce(v_department_name, nullif(trim(coalesce(v_profile.bo_phan,'')), ''));

  if v_profile.role in ('NhanVienMuaHang','TruongPhong') and v_profile.department_id is null then
    raise exception 'Tài khoản cần được Admin gán bộ phận trước khi sử dụng.';
  end if;

  if v_profile.role = 'Admin' then v_perms := to_jsonb(array['*']::text[]);
  else select coalesce(jsonb_agg(permission), '[]'::jsonb) into v_perms from role_permissions where role = v_profile.role; end if;

  v_all := v_profile.role not in ('NhanVienMuaHang','TruongPhong');

  return jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'email', v_profile.email, 'name', v_profile.name, 'role', v_profile.role,
      'departmentId', v_profile.department_id, 'boPhan', v_department_name
    ),
    'doiTuong', (
      select coalesce(jsonb_agg(jsonb_build_object('MaDoiTuong', ma_doi_tuong, 'TenDoiTuong', ten_doi_tuong, 'DieuKhoanTT_MacDinh', dieu_khoan_tt_mac_dinh) order by ten_doi_tuong), '[]'::jsonb)
      from doi_tuong where trang_thai = 'Hoạt động' and (v_all or bo_phan is null or bo_phan = v_department_name)),
    'vatTu', (select coalesce(jsonb_agg(ten order by ten), '[]'::jsonb) from materials where (v_all or bo_phan is null or bo_phan = v_department_name)),
    'vatTuInfo', (select coalesce(jsonb_agg(jsonb_build_object('ten', ten, 'dvt', dvt) order by ten), '[]'::jsonb) from materials where (v_all or bo_phan is null or bo_phan = v_department_name)),
    'permissions', v_perms
  );
end; $$;

create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_all boolean; v_department_name text; v_materials jsonb; v_suppliers jsonb; v_groups jsonb; v_depts jsonb; v_props jsonb;
begin
  v_actor := require_permission('catalog:read');
  select ten into v_department_name from departments where id = v_actor.department_id;
  v_department_name := coalesce(v_department_name, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  v_all := v_actor.role not in ('NhanVienMuaHang','TruongPhong');

  select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb) into v_groups from material_groups;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'ten', ten) order by ten), '[]'::jsonb) into v_depts from departments;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'ten', p.ten, 'departmentId', p.department_id, 'boPhan', coalesce(d.ten, p.bo_phan)
    ) order by p.ten), '[]'::jsonb)
    into v_props
    from proposers p left join departments d on d.id = p.department_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_vat_tu, 'ten', ten, 'dvt', dvt, 'nhom', nhom, 'boPhan', bo_phan, 'trangThai', trang_thai
    ) order by nhom nulls last, ten), '[]'::jsonb)
  into v_materials from materials where (v_all or bo_phan is null or bo_phan = v_department_name);

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_doi_tuong, 'ten', ten_doi_tuong, 'loai', loai, 'mst', mst, 'diaChi', dia_chi,
      'contact', contact, 'sdt', sdt, 'dieuKhoan', dieu_khoan_tt_mac_dinh, 'moq', moq,
      'soTk', so_tk_ngan_hang, 'chiNhanh', chi_nhanh_ngan_hang, 'boPhan', bo_phan, 'trangThai', trang_thai
    ) order by ten_doi_tuong), '[]'::jsonb)
  into v_suppliers from doi_tuong where (v_all or bo_phan is null or bo_phan = v_department_name);

  return jsonb_build_object('ok', true, 'groups', v_groups, 'departments', v_depts, 'proposers', v_props,
    'materials', v_materials, 'suppliers', v_suppliers,
    'canCreate', (v_actor.role = 'Admin' or has_permission(v_actor.role, 'catalog:create')),
    'canManage', (v_actor.role = 'Admin' or has_permission(v_actor.role, 'catalog:manage')));
end; $$;

-- Admin user management ------------------------------------------------------
drop function if exists rpc_admin_create_user(text, text, text, text);
create or replace function rpc_admin_create_user(p_email text, p_name text, p_role text, p_pin text, p_department_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor profiles; v_uid uuid := gen_random_uuid();
  v_email text := lower(trim(coalesce(p_email,''))); v_pin text := trim(coalesce(p_pin,'')); v_pw text;
  v_department_name text;
begin
  v_actor := require_permission('user:manage');
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'Email không hợp lệ.'; end if;
  if p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if p_role in ('NhanVienMuaHang','TruongPhong') and p_department_id is null then
    raise exception 'Nhân viên mua hàng và Trưởng phòng bắt buộc có bộ phận.';
  end if;
  if p_department_id is not null then
    select ten into v_department_name from departments where id = p_department_id;
    if v_department_name is null then raise exception 'Bộ phận không tồn tại trong danh mục.'; end if;
  end if;
  if length(v_pin) < 4 then raise exception 'Mã PIN cần ít nhất 4 ký tự.'; end if;
  if exists (select 1 from auth.users where email = v_email) then raise exception 'Email % đã tồn tại.', v_email; end if;
  v_pw := 'tn-pin::' || v_pin;
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
    crypt(v_pw, gen_salt('bf')), now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', coalesce(nullif(trim(p_name),''), v_email)),
    false, '', '', '', ''
  );
  insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid::text, v_uid, jsonb_build_object('sub', v_uid::text, 'email', v_email), 'email', now(), now(), now());
  insert into profiles (id, email, name, role, status, department_id, bo_phan)
  values (v_uid, v_email, coalesce(nullif(trim(p_name),''), v_email), p_role, 'Hoạt động', p_department_id, v_department_name);
  perform write_audit(v_actor, 'CREATE_USER', 'profiles', v_uid::text, null,
    jsonb_build_object('email', v_email, 'role', p_role, 'departmentId', p_department_id, 'boPhan', v_department_name), 'OK', '');
  return jsonb_build_object('ok', true, 'id', v_uid, 'email', v_email);
end; $$;

create or replace function rpc_admin_list_users() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('user:manage');
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'email', p.email, 'name', p.name, 'role', p.role, 'status', p.status,
    'departmentId', p.department_id, 'boPhan', coalesce(d.ten, p.bo_phan),
    'createdAt', to_char(p.created_at, 'YYYY-MM-DD')
  ) order by p.created_at), '[]'::jsonb)
  into v_rows
  from profiles p left join departments d on d.id = p.department_id;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

drop function if exists rpc_admin_update_user(uuid, text, text, text, text);
create or replace function rpc_admin_update_user(
  p_id uuid,
  p_role text default null,
  p_status text default null,
  p_name text default null,
  p_bo_phan text default null,
  p_department_id uuid default null
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_before jsonb; v_current profiles; v_row profiles;
  v_role text; v_status text; v_department_id uuid; v_department_name text;
begin
  v_actor := require_permission('user:manage');
  select * into v_current from profiles where id = p_id;
  if v_current is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  v_before := to_jsonb(v_current);

  v_role := coalesce(nullif(trim(coalesce(p_role,'')),''), v_current.role);
  v_status := coalesce(nullif(trim(coalesce(p_status,'')),''), v_current.status);
  if v_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if v_status not in ('Hoạt động','Ngừng') then raise exception 'Trạng thái không hợp lệ.'; end if;

  v_department_id := v_current.department_id;
  v_department_name := v_current.bo_phan;

  if p_department_id is not null then
    v_department_id := p_department_id;
    select ten into v_department_name from departments where id = v_department_id;
    if v_department_name is null then raise exception 'Bộ phận không tồn tại trong danh mục.'; end if;
  elsif p_bo_phan is not null then
    v_department_name := nullif(trim(coalesce(p_bo_phan,'')), '');
    if v_department_name is null then
      v_department_id := null;
    else
      select id, ten into v_department_id, v_department_name
      from departments
      where normalize_text(ten) = normalize_text(v_department_name)
      order by created_at, ten
      limit 1;
      if v_department_id is null then raise exception 'Bộ phận "%" chưa có trong danh mục. Hãy thêm bộ phận trước.', p_bo_phan; end if;
    end if;
  elsif v_department_id is not null then
    select ten into v_department_name from departments where id = v_department_id;
  end if;

  if v_status = 'Hoạt động' and v_role in ('NhanVienMuaHang','TruongPhong') and v_department_id is null then
    raise exception 'Nhân viên mua hàng và Trưởng phòng bắt buộc có bộ phận trước khi tài khoản hoạt động.';
  end if;

  update profiles set
    role = v_role,
    status = v_status,
    name = coalesce(nullif(trim(coalesce(p_name,'')),''), name),
    department_id = v_department_id,
    bo_phan = v_department_name
  where id = p_id returning * into v_row;
  perform write_audit(v_actor, 'UPDATE_USER', 'profiles', p_id::text, v_before, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'id', p_id);
end; $$;

-- Proposals ------------------------------------------------------------------
create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status','Nháp')='Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_loai text := case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end;
  v_in_plan boolean := coalesce((p_payload->>'trongKeHoachTuan')::boolean,false);
  v_giai_trinh text := nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),'');
  v_actor profiles; v_dt doi_tuong; v_ma text; v_pid uuid; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0; v_h jsonb;
  v_department_id uuid; v_department_name text;
begin
  v_actor := require_permission(case when v_status='Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);
  v_department_id := v_actor.department_id;
  select ten into v_department_name from departments where id = v_department_id;
  v_department_name := coalesce(v_department_name, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  if v_actor.role in ('NhanVienMuaHang','TruongPhong') and v_department_id is null then
    raise exception 'Tài khoản cần được Admin gán bộ phận trước khi tạo đề xuất.';
  end if;
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines')=0 then raise exception 'Đề xuất cần ít nhất một dòng vật tư.'; end if;
  if v_status='Chờ duyệt' and not v_in_plan and v_giai_trinh is null then raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.'; end if;
  if v_status='Chờ duyệt' and v_loai='MuaHang' and jsonb_array_length(p_payload->'lines') >= 2
     and coalesce(jsonb_array_length(p_payload->'attachments'),0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;
  v_dt := ensure_doi_tuong(p_payload->'doiTuong'->>'ma', p_payload->'doiTuong'->>'ten', coalesce(p_payload->'doiTuong'->>'loai','NCC'),
    p_payload->'doiTuong'->>'mst', p_payload->'doiTuong'->>'diaChi', p_payload->'doiTuong'->>'contact', coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  v_ma := next_code('DX');
  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, department_id, doi_tuong_id, ten_doi_tuong, noi_dung,
    dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan, giai_trinh_ngoai_ke_hoach,
    han_thanh_toan, ton_kho, truong_bp_duyet, prepay, prepay_percent, attachments)
  values (v_ma, coalesce((p_payload->>'ngayDeXuat')::date, current_date), coalesce(nullif(trim(p_payload->>'nguoiDeNghi'),''), v_actor.name),
    v_department_name, v_department_id, v_dt.id, v_dt.ten_doi_tuong, p_payload->>'noiDung',
    coalesce(p_payload->>'dieuKhoanTT', v_dt.dieu_khoan_tt_mac_dinh), v_status, v_actor.id, p_payload->>'ghiChu',
    v_loai, v_in_plan, v_giai_trinh, (p_payload->>'hanThanhToan')::date, parse_number(p_payload->>'tonKho'),
    coalesce((p_payload->>'truongBpDuyet')::boolean,false), coalesce((p_payload->>'prepay')::boolean,false),
    parse_number(p_payload->>'prepayPercent'), coalesce(p_payload->'attachments','[]'::jsonb))
  returning id into v_pid;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat'); v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then continue; end if;
    v_vat := parse_vat_rate(v_line->>'vat'); perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (next_code('DXL'), v_pid, trim(v_line->>'matHang'), v_qty, v_price, v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', v_status);
    v_n := v_n + 1;
  end loop;
  if v_n=0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;
  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai, 'BoPhan', bo_phan, 'DepartmentId', department_id) into v_h from proposals where id=v_pid;
  perform write_audit(v_actor,'CREATE_PROPOSAL','proposals',v_ma,null,v_h,'OK',v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma, 'status', v_status);
end; $$;

create or replace function rpc_update_proposal(p_ma_de_xuat text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_p proposals; v_dt doi_tuong; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0;
  v_department_id uuid; v_department_name text;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ sửa được phiếu Nháp.'; end if;
  if v_actor.role in ('NhanVienMuaHang','TruongPhong') and v_actor.department_id is null then
    raise exception 'Tài khoản cần được Admin gán bộ phận trước khi sửa đề xuất.';
  end if;

  -- Existing proposals keep the department snapshot they had at creation time.
  -- If a legacy draft has no department yet, backfill from the actor.
  v_department_id := v_p.department_id;
  v_department_name := nullif(trim(coalesce(v_p.bo_phan,'')), '');
  if v_department_id is null and v_department_name is not null then
    select id into v_department_id from departments where normalize_text(ten) = normalize_text(v_department_name) order by created_at, ten limit 1;
  end if;
  if v_department_name is null and v_department_id is not null then
    select ten into v_department_name from departments where id = v_department_id;
  end if;
  if v_department_name is null then
    v_department_id := v_actor.department_id;
    select ten into v_department_name from departments where id = v_department_id;
    v_department_name := coalesce(v_department_name, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  end if;
  v_dt := ensure_doi_tuong(null, p_payload->'doiTuong'->>'ten', 'NCC', null, null, null, coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  update proposals set
    loai_de_xuat = case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end,
    ngay_de_xuat = coalesce((p_payload->>'ngayDeXuat')::date, ngay_de_xuat),
    nguoi_de_nghi = coalesce(nullif(trim(p_payload->>'nguoiDeNghi'),''), nguoi_de_nghi),
    bo_phan = v_department_name,
    department_id = v_department_id,
    doi_tuong_id = v_dt.id, ten_doi_tuong = v_dt.ten_doi_tuong, noi_dung = p_payload->>'noiDung',
    dieu_khoan_tt = coalesce(p_payload->>'dieuKhoanTT', dieu_khoan_tt), han_thanh_toan = (p_payload->>'hanThanhToan')::date,
    ton_kho = parse_number(p_payload->>'tonKho'), truong_bp_duyet = coalesce((p_payload->>'truongBpDuyet')::boolean,false),
    prepay = coalesce((p_payload->>'prepay')::boolean,false),
    prepay_percent = parse_number(p_payload->>'prepayPercent'),
    trong_ke_hoach_tuan = coalesce((p_payload->>'trongKeHoachTuan')::boolean,false),
    giai_trinh_ngoai_ke_hoach = nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),''),
    attachments = case when p_payload ? 'attachments' and jsonb_array_length(p_payload->'attachments')>0 then p_payload->'attachments' else attachments end
  where id = v_p.id;
  delete from proposal_lines where proposal_id = v_p.id;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat'); v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then continue; end if;
    v_vat := parse_vat_rate(v_line->>'vat'); perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (next_code('DXL'), v_p.id, trim(v_line->>'matHang'), v_qty, v_price, v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', 'Nháp');
    v_n := v_n + 1;
  end loop;
  if v_n=0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

create or replace function rpc_get_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  select jsonb_build_object('MaDeXuat', v_p.ma_de_xuat, 'TrangThai', v_p.trang_thai, 'LoaiDeXuat', v_p.loai_de_xuat,
    'NgayDeXuat', to_char(v_p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', v_p.nguoi_de_nghi, 'BoPhan', v_p.bo_phan, 'DepartmentId', v_p.department_id,
    'TenDoiTuong', v_p.ten_doi_tuong, 'DieuKhoanTT', v_p.dieu_khoan_tt, 'HanThanhToan', to_char(v_p.han_thanh_toan,'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho, 'TruongBpDuyet', v_p.truong_bp_duyet, 'Prepay', v_p.prepay, 'PrepayPercent', v_p.prepay_percent, 'LyDoTraLai', v_p.ly_do_tra_lai,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach, 'Attachments', v_p.attachments,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('matHang', l.mat_hang, 'slDat', l.sl_dat, 'donGia', l.don_gia_chua_vat, 'vat', (l.vat_rate*100)||'%', 'ghiChu', l.ghi_chu) order by l.ma_line),'[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id))
  into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

create or replace function rpc_submit_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_p proposals;
  v_department_id uuid; v_department_name text;
begin
  v_actor := require_permission('proposal:submit');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ gửi duyệt được phiếu đang ở trạng thái Nháp.'; end if;
  if v_actor.role in ('NhanVienMuaHang','TruongPhong') and v_actor.department_id is null then
    raise exception 'Tài khoản cần được Admin gán bộ phận trước khi gửi duyệt.';
  end if;
  if not v_p.trong_ke_hoach_tuan and nullif(trim(coalesce(v_p.giai_trinh_ngoai_ke_hoach,'')),'') is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.';
  end if;
  if v_p.loai_de_xuat = 'MuaHang'
     and (select count(*) from proposal_lines where proposal_id = v_p.id) >= 2
     and coalesce(jsonb_array_length(v_p.attachments), 0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;

  v_department_id := v_p.department_id;
  v_department_name := nullif(trim(coalesce(v_p.bo_phan,'')), '');
  if v_department_id is null and v_department_name is not null then
    select id into v_department_id from departments where normalize_text(ten) = normalize_text(v_department_name) order by created_at, ten limit 1;
  end if;
  if v_department_name is null and v_department_id is not null then
    select ten into v_department_name from departments where id = v_department_id;
  end if;
  if v_department_name is null then
    v_department_id := v_actor.department_id;
    select ten into v_department_name from departments where id = v_department_id;
  end if;

  update proposals
  set trang_thai = 'Chờ duyệt',
      ly_do_tra_lai = null,
      department_id = v_department_id,
      bo_phan = v_department_name
  where id = v_p.id;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

-- Department-head oversight uses hidden IDs, with text fallback for legacy rows.
create or replace function rpc_oversight(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_props jsonb; v_pays jsonb; v_tbp boolean; v_actor_dept text;
begin
  v_actor := require_permission('oversight:read');
  v_tbp := (v_actor.role = 'TruongPhong');
  select ten into v_actor_dept from departments where id = v_actor.department_id;
  v_actor_dept := coalesce(v_actor_dept, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  if v_tbp and v_actor.department_id is null then
    raise exception 'Tài khoản Trưởng phòng cần được Admin gán bộ phận trước khi rà soát.';
  end if;

  select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_props
  from (
    select jsonb_build_object(
      'MaDeXuat', p.ma_de_xuat, 'Loai', case when p.loai_de_xuat='TamUng' then 'Tạm ứng' else 'Mua hàng' end,
      'Ngay', to_char(p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', p.nguoi_de_nghi, 'BoPhan', p.bo_phan, 'DepartmentId', p.department_id,
      'TenDoiTuong', p.ten_doi_tuong, 'TrangThai', p.trang_thai, 'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'),
      'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id=p.id),0),
      'DaNghiemThu', exists(select 1 from debts d where d.proposal_id=p.id and d.sl_thuc_nhan is not null),
      'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id=p.id and d.da_thanh_toan>0),
      'ThoiGianTao', to_char(p.created_at,'YYYY-MM-DD HH24:MI'), 'ThoiGianDuyet', to_char(p.approved_at,'YYYY-MM-DD HH24:MI'), 'NguoiDuyet', (select name from profiles where id=p.nguoi_duyet)
    ) as x
    from proposals p
    where (p_from is null or p.ngay_de_xuat >= p_from) and (p_to is null or p.ngay_de_xuat <= p_to)
      and (
        not v_tbp
        or (
          p.trang_thai <> 'Nháp'
          and (
            (v_actor.department_id is not null and p.department_id = v_actor.department_id)
            or (p.department_id is null and v_actor_dept is not null and p.bo_phan = v_actor_dept)
          )
        )
      )
    order by p.ngay_de_xuat desc limit 500
  ) t;

  if v_tbp then
    v_pays := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_pays
    from (
      select jsonb_build_object(
        'MaDeXuatTT', pr.ma_de_xuat_tt, 'Ngay', to_char(pr.ngay,'YYYY-MM-DD'), 'TrangThai', pr.trang_thai,
        'NguoiLap', (select name from profiles where id=pr.nguoi_lap),
        'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id=pr.id),0)
      ) as x
      from payment_requests pr
      where (p_from is null or pr.ngay >= p_from) and (p_to is null or pr.ngay <= p_to)
      order by pr.ngay desc limit 500
    ) t;
  end if;

  return jsonb_build_object('ok', true, 'role', v_actor.role, 'proposals', v_props, 'paymentRequests', v_pays);
end; $$;

create or replace function rpc_cancel_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_actor_dept text;
begin
  v_actor := require_permission('oversight:cancel');
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cần nhập lý do hủy để báo người lập.'; end if;
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai <> 'Chờ duyệt' then raise exception 'Chỉ hủy được phiếu đang CHỜ DUYỆT (trước khi sếp duyệt).'; end if;
  select ten into v_actor_dept from departments where id = v_actor.department_id;
  v_actor_dept := coalesce(v_actor_dept, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  if v_actor.role = 'TruongPhong' and v_actor.department_id is null then
    raise exception 'Tài khoản Trưởng phòng cần được Admin gán bộ phận trước khi rà soát.';
  end if;
  if v_actor.role = 'TruongPhong' and not (
    (v_actor.department_id is not null and v_p.department_id = v_actor.department_id)
    or (v_p.department_id is null and v_actor_dept is not null and v_p.bo_phan = v_actor_dept)
  ) then
    raise exception 'Trưởng bộ phận chỉ được hủy phiếu thuộc bộ phận mình.';
  end if;
  update proposals set trang_thai = 'Từ chối', ghi_chu = coalesce(ghi_chu,'') || ' | HỦY (rà soát) bởi ' || coalesce(v_actor.name,'') || ': ' || trim(p_reason)
  where id = v_p.id;
  perform write_audit(v_actor, 'CANCEL_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_p), jsonb_build_object('reason', p_reason), 'OK', trim(p_reason));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

create or replace function rpc_oversight_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb; v_actor_dept text;
begin
  v_actor := require_permission('oversight:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  select ten into v_actor_dept from departments where id = v_actor.department_id;
  v_actor_dept := coalesce(v_actor_dept, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  if v_actor.role = 'TruongPhong' and v_actor.department_id is null then
    raise exception 'Tài khoản Trưởng phòng cần được Admin gán bộ phận trước khi rà soát.';
  end if;
  if v_actor.role = 'TruongPhong' and not (
    (v_actor.department_id is not null and v_p.department_id = v_actor.department_id)
    or (v_p.department_id is null and v_actor_dept is not null and v_p.bo_phan = v_actor_dept)
  ) then
    raise exception 'Trưởng bộ phận chỉ xem được phiếu thuộc bộ phận mình.';
  end if;

  select jsonb_build_object(
    'MaDeXuat', v_p.ma_de_xuat,
    'LoaiDeXuat', v_p.loai_de_xuat,
    'TrangThai', v_p.trang_thai,
    'BoPhan', v_p.bo_phan,
    'DepartmentId', v_p.department_id,
    'NguoiDeNghi', v_p.nguoi_de_nghi,
    'NguoiTao', (select name from profiles where id = v_p.nguoi_tao),
    'TenDoiTuong', v_p.ten_doi_tuong,
    'DieuKhoanTT', v_p.dieu_khoan_tt,
    'HanThanhToan', to_char(v_p.han_thanh_toan, 'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho,
    'TruongBpDuyet', v_p.truong_bp_duyet,
    'Prepay', v_p.prepay, 'PrepayPercent', v_p.prepay_percent,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan,
    'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach,
    'NoiDung', v_p.noi_dung,
    'GhiChu', v_p.ghi_chu,
    'LyDoTraLai', v_p.ly_do_tra_lai,
    'Attachments', coalesce(v_p.attachments, '[]'::jsonb),
    'ThoiGianTao', to_char(v_p.created_at, 'YYYY-MM-DD HH24:MI'),
    'ThoiGianDuyet', to_char(v_p.approved_at, 'YYYY-MM-DD HH24:MI'),
    'NguoiDuyet', (select name from profiles where id = v_p.nguoi_duyet),
    'DaNghiemThu', exists(select 1 from debts d where d.proposal_id = v_p.id and d.sl_thuc_nhan is not null),
    'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id = v_p.id and d.da_thanh_toan > 0),
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines where proposal_id = v_p.id), 0),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
        'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu
      ) order by l.ma_line), '[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id)
  ) into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

create or replace function rpc_bounce_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_reason text := nullif(trim(coalesce(p_reason,'')),''); v_removed int := 0; v_actor_dept text;
begin
  v_actor := require_permission('oversight:cancel');
  if v_reason is null then raise exception 'Cần nhập lý do trả lại để người lập giải trình.'; end if;
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai not in ('Chờ duyệt','Đã duyệt') then
    raise exception 'Chỉ trả lại được phiếu đang CHỜ DUYỆT hoặc ĐÃ DUYỆT (chưa thanh toán).';
  end if;
  select ten into v_actor_dept from departments where id = v_actor.department_id;
  v_actor_dept := coalesce(v_actor_dept, nullif(trim(coalesce(v_actor.bo_phan,'')), ''));
  if v_actor.role = 'TruongPhong' and v_actor.department_id is null then
    raise exception 'Tài khoản Trưởng phòng cần được Admin gán bộ phận trước khi rà soát.';
  end if;
  if v_actor.role = 'TruongPhong' and not (
    (v_actor.department_id is not null and v_p.department_id = v_actor.department_id)
    or (v_p.department_id is null and v_actor_dept is not null and v_p.bo_phan = v_actor_dept)
  ) then
    raise exception 'Trưởng bộ phận chỉ được trả lại phiếu thuộc bộ phận mình.';
  end if;

  if v_p.trang_thai = 'Đã duyệt' then
    if exists (select 1 from debts d where d.proposal_id = v_p.id and (d.da_thanh_toan > 0 or d.is_archived)) then
      raise exception 'Phiếu đã phát sinh thanh toán/đã tất toán — không thể trả lại. Hãy hủy khoản thanh toán trước.';
    end if;
    if exists (select 1 from payment_request_lines prl join debts d on d.id = prl.debt_id where d.proposal_id = v_p.id) then
      raise exception 'Công nợ của phiếu đang nằm trong một đề xuất thanh toán — hãy hủy đề xuất thanh toán đó trước.';
    end if;
    update proposal_lines set trang_thai = 'Nháp', debt_id = null where proposal_id = v_p.id;
    delete from debts where proposal_id = v_p.id;
    get diagnostics v_removed = row_count;
  end if;

  update proposals set
    trang_thai = 'Nháp', nguoi_duyet = null, approved_at = null,
    ly_do_tra_lai = v_reason,
    ghi_chu = coalesce(ghi_chu,'') || ' | TRẢ LẠI (rà soát) bởi ' || coalesce(v_actor.name,'') || ': ' || v_reason
  where id = v_p.id;

  if v_p.nguoi_tao is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (v_p.nguoi_tao, 'proposal_bounced',
            'Đề xuất bị trả lại — cần giải trình',
            v_p.ma_de_xuat || ' bị ' || coalesce(v_actor.name,'(rà soát)') || ' (' || v_actor.role || ') trả lại: ' || v_reason,
            'proposal', v_p.ma_de_xuat);
  end if;

  perform write_audit(v_actor, 'BOUNCE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_p),
    jsonb_build_object('reason', v_reason, 'debtsRemoved', v_removed), 'OK', v_reason);
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'debtsRemoved', v_removed);
end; $$;

grant execute on function rpc_add_department(text) to authenticated;
grant execute on function rpc_add_proposer(text, text, uuid) to authenticated;
grant execute on function rpc_bootstrap() to authenticated;
grant execute on function rpc_list_catalog() to authenticated;
grant execute on function rpc_admin_create_user(text, text, text, text, uuid) to authenticated;
grant execute on function rpc_admin_list_users() to authenticated;
grant execute on function rpc_admin_update_user(uuid, text, text, text, text, uuid) to authenticated;
grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_update_proposal(text, jsonb) to authenticated;
grant execute on function rpc_get_proposal(text) to authenticated;
grant execute on function rpc_submit_proposal(text) to authenticated;
grant execute on function rpc_oversight(date, date) to authenticated;
grant execute on function rpc_cancel_proposal(text, text) to authenticated;
grant execute on function rpc_oversight_proposal_detail(text) to authenticated;
grant execute on function rpc_bounce_proposal(text, text) to authenticated;
