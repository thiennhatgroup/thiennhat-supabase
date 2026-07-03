-- ============================================================================
-- 0049_dept_catalog_selfservice.sql  (Đợt B1)
--  * Danh mục theo BỘ PHẬN: materials.bo_phan, doi_tuong.bo_phan. NVMH/Trưởng BP
--    chỉ thấy vật tư/NCC của bộ phận mình (hoặc dùng chung — bo_phan null). Kế
--    toán/lãnh đạo/Admin thấy tất cả.
--  * NVMH tự tạo vật tư/NCC (catalog:create) — mã do hệ thống tự sinh, gắn bộ
--    phận người tạo. Dùng cho popup tạo nhanh khi nhập báo giá / đề xuất.
-- ============================================================================

alter table materials  add column if not exists bo_phan text;
alter table doi_tuong  add column if not exists bo_phan text;

insert into role_permissions (role, permission) values
  ('NhanVienMuaHang', 'catalog:create')
on conflict (role, permission) do nothing;

-- ---- NVMH tạo nhanh 1 mặt hàng (mã tự sinh, gắn bộ phận) --------------------
create or replace function rpc_create_material_quick(p_ten text, p_dvt text default null, p_nhom text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ten text := nullif(trim(coalesce(p_ten,'')),''); v_row materials;
begin
  v_actor := require_permission('catalog:create');
  if v_ten is null then raise exception 'Cần nhập tên mặt hàng.'; end if;
  select * into v_row from materials where normalize_text(ten) = normalize_text(v_ten) limit 1;
  if v_row.id is not null then
    return jsonb_build_object('ok', true, 'existed', true, 'ma', v_row.ma_vat_tu, 'ten', v_row.ten, 'dvt', v_row.dvt);
  end if;
  insert into materials (ten, dvt, nhom, trang_thai, ma_vat_tu, bo_phan)
  values (v_ten, nullif(trim(coalesce(p_dvt,'')),''), nullif(trim(coalesce(p_nhom,'')),''), 'Hoạt động', next_material_code(), v_actor.bo_phan)
  returning * into v_row;
  perform write_audit(v_actor, 'CREATE_MATERIAL_QUICK', 'materials', v_row.ma_vat_tu, null, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'existed', false, 'ma', v_row.ma_vat_tu, 'ten', v_row.ten, 'dvt', v_row.dvt);
end; $$;

-- ---- NVMH tạo nhanh 1 nhà cung cấp (mã tự sinh, gắn bộ phận) ----------------
create or replace function rpc_create_supplier_quick(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ten text := nullif(trim(coalesce(p_payload->>'ten','')),''); v_row doi_tuong;
begin
  v_actor := require_permission('catalog:create');
  if v_ten is null then raise exception 'Cần nhập tên nhà cung cấp.'; end if;
  select * into v_row from doi_tuong
   where normalize_text(ten_doi_tuong) = normalize_text(v_ten)
     and (bo_phan is not distinct from v_actor.bo_phan or bo_phan is null) limit 1;
  if v_row.id is not null then
    return jsonb_build_object('ok', true, 'existed', true, 'ma', v_row.ma_doi_tuong, 'ten', v_row.ten_doi_tuong);
  end if;
  insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, dia_chi, contact, sdt,
    dieu_khoan_tt_mac_dinh, moq, so_tk_ngan_hang, chi_nhanh_ngan_hang, trang_thai, bo_phan)
  values (next_code('DT'), v_ten, 'NCC', p_payload->>'mst', p_payload->>'diaChi', p_payload->>'contact', p_payload->>'sdt',
    p_payload->>'dieuKhoan', p_payload->>'moq', p_payload->>'soTk', p_payload->>'chiNhanh', 'Hoạt động', v_actor.bo_phan)
  returning * into v_row;
  perform write_audit(v_actor, 'CREATE_SUPPLIER_QUICK', 'doi_tuong', v_row.ma_doi_tuong, null, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'existed', false, 'ma', v_row.ma_doi_tuong, 'ten', v_row.ten_doi_tuong,
    'MaDoiTuong', v_row.ma_doi_tuong, 'TenDoiTuong', v_row.ten_doi_tuong, 'DieuKhoanTT_MacDinh', v_row.dieu_khoan_tt_mac_dinh);
end; $$;

-- ---- Bootstrap: danh sách vật tư/NCC theo bộ phận + trả về boPhan ------------
create or replace function rpc_bootstrap() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile profiles; v_perms jsonb; v_all boolean;
begin
  select * into v_profile from profiles where id = auth.uid();
  if v_profile is null then raise exception 'Tài khoản chưa được cấp quyền truy cập hệ thống. Hãy liên hệ Admin để tạo hồ sơ trong bảng profiles.'; end if;
  if v_profile.status <> 'Hoạt động' then raise exception 'Tài khoản chưa ở trạng thái Hoạt động.'; end if;

  if v_profile.role = 'Admin' then v_perms := to_jsonb(array['*']::text[]);
  else select coalesce(jsonb_agg(permission), '[]'::jsonb) into v_perms from role_permissions where role = v_profile.role; end if;

  v_all := v_profile.role not in ('NhanVienMuaHang','TruongPhong');

  return jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object('email', v_profile.email, 'name', v_profile.name, 'role', v_profile.role, 'boPhan', v_profile.bo_phan),
    'doiTuong', (
      select coalesce(jsonb_agg(jsonb_build_object('MaDoiTuong', ma_doi_tuong, 'TenDoiTuong', ten_doi_tuong, 'DieuKhoanTT_MacDinh', dieu_khoan_tt_mac_dinh) order by ten_doi_tuong), '[]'::jsonb)
      from doi_tuong where trang_thai = 'Hoạt động' and (v_all or bo_phan is null or bo_phan = v_profile.bo_phan)),
    'vatTu', (select coalesce(jsonb_agg(ten order by ten), '[]'::jsonb) from materials where (v_all or bo_phan is null or bo_phan = v_profile.bo_phan)),
    'vatTuInfo', (select coalesce(jsonb_agg(jsonb_build_object('ten', ten, 'dvt', dvt) order by ten), '[]'::jsonb) from materials where (v_all or bo_phan is null or bo_phan = v_profile.bo_phan)),
    'permissions', v_perms
  );
end; $$;

-- ---- Danh mục: lọc theo bộ phận + cột bộ phận + cờ quyền tạo/quản lý --------
create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_all boolean; v_materials jsonb; v_suppliers jsonb; v_groups jsonb;
begin
  v_actor := require_permission('catalog:read');
  v_all := v_actor.role not in ('NhanVienMuaHang','TruongPhong');

  select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb) into v_groups from material_groups;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_vat_tu, 'ten', ten, 'dvt', dvt, 'nhom', nhom, 'boPhan', bo_phan, 'trangThai', trang_thai
    ) order by nhom nulls last, ten), '[]'::jsonb)
  into v_materials from materials where (v_all or bo_phan is null or bo_phan = v_actor.bo_phan);

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_doi_tuong, 'ten', ten_doi_tuong, 'loai', loai, 'mst', mst, 'diaChi', dia_chi,
      'contact', contact, 'sdt', sdt, 'dieuKhoan', dieu_khoan_tt_mac_dinh, 'moq', moq,
      'soTk', so_tk_ngan_hang, 'chiNhanh', chi_nhanh_ngan_hang, 'boPhan', bo_phan, 'trangThai', trang_thai
    ) order by ten_doi_tuong), '[]'::jsonb)
  into v_suppliers from doi_tuong where (v_all or bo_phan is null or bo_phan = v_actor.bo_phan);

  return jsonb_build_object('ok', true, 'groups', v_groups, 'materials', v_materials, 'suppliers', v_suppliers,
    'canCreate', (v_actor.role = 'Admin' or has_permission(v_actor.role, 'catalog:create')),
    'canManage', (v_actor.role = 'Admin' or has_permission(v_actor.role, 'catalog:manage')));
end; $$;

grant execute on function rpc_create_material_quick(text, text, text) to authenticated;
grant execute on function rpc_create_supplier_quick(jsonb) to authenticated;
grant execute on function rpc_bootstrap() to authenticated;
grant execute on function rpc_list_catalog() to authenticated;
