-- ============================================================================
-- 0014_rpc_catalog.sql
-- SECURITY DEFINER RPCs for the in-app "Danh mục" (master data) screen.
--   rpc_list_catalog()      -> materials + suppliers + the fixed group list
--   rpc_upsert_material()   -> insert/update a material (catalog:manage)
--   rpc_upsert_doi_tuong()  -> insert/update a supplier (catalog:manage)
-- Reads require catalog:read; writes require catalog:manage. Admin bypasses.
-- ============================================================================

create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_materials jsonb;
  v_suppliers jsonb;
begin
  perform require_permission('catalog:read');

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_vat_tu, 'ten', ten, 'dvt', dvt,
      'nhom', nhom, 'trangThai', trang_thai
    ) order by nhom nulls last, ten), '[]'::jsonb)
  into v_materials from materials;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_doi_tuong, 'ten', ten_doi_tuong, 'loai', loai,
      'mst', mst, 'diaChi', dia_chi, 'contact', contact, 'sdt', sdt,
      'dieuKhoan', dieu_khoan_tt_mac_dinh, 'moq', moq, 'trangThai', trang_thai
    ) order by ten_doi_tuong), '[]'::jsonb)
  into v_suppliers from doi_tuong;

  return jsonb_build_object(
    'ok', true,
    'groups', to_jsonb(array[
      'Nhựa đường & nhũ tương',
      'Đá & cát',
      'Xi măng',
      'Dầu diesel',
      'Dầu & mỡ chuyên dụng',
      'Vật tư phụ tùng sửa chữa'
    ]::text[]),
    'materials', v_materials,
    'suppliers', v_suppliers
  );
end;
$$;

-- Insert or update a material. Payload:
--   { "id": uuid|null, "ten": "...", "maVatTu": "VT-0007"|null (auto if blank on insert),
--     "dvt": "...", "nhom": "...", "trangThai": "Hoạt động"|"Ngừng" }
create or replace function rpc_upsert_material(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor  profiles;
  v_id     uuid := nullif(p_payload->>'id','')::uuid;
  v_ten    text := nullif(trim(coalesce(p_payload->>'ten','')), '');
  v_ma     text := nullif(trim(coalesce(p_payload->>'maVatTu','')), '');
  v_dvt    text := nullif(trim(coalesce(p_payload->>'dvt','')), '');
  v_nhom   text := nullif(trim(coalesce(p_payload->>'nhom','')), '');
  v_status text := coalesce(nullif(trim(coalesce(p_payload->>'trangThai','')),''), 'Hoạt động');
  v_before jsonb;
  v_row    materials;
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then
    raise exception 'Cần nhập tên mặt hàng.';
  end if;
  if v_status not in ('Hoạt động','Ngừng') then
    raise exception 'Trạng thái không hợp lệ.';
  end if;

  -- Name must be unique (diacritic-insensitive), excluding the row being edited.
  if exists (
    select 1 from materials
    where normalize_text(ten) = normalize_text(v_ten)
      and (v_id is null or id <> v_id)
  ) then
    raise exception 'Mặt hàng "%" đã tồn tại.', v_ten;
  end if;
  -- Code, if supplied, must also be unique.
  if v_ma is not null and exists (
    select 1 from materials where ma_vat_tu = v_ma and (v_id is null or id <> v_id)
  ) then
    raise exception 'Mã vật tư "%" đã được dùng.', v_ma;
  end if;

  if v_id is null then
    insert into materials (ten, dvt, nhom, trang_thai, ma_vat_tu)
    values (v_ten, v_dvt, v_nhom, v_status, coalesce(v_ma, next_material_code()))
    returning * into v_row;
    perform write_audit(v_actor, 'CREATE_MATERIAL', 'materials', v_row.id::text, null, to_jsonb(v_row), 'OK', '');
  else
    select to_jsonb(m) into v_before from materials m where id = v_id;
    if v_before is null then
      raise exception 'Không tìm thấy mặt hàng để cập nhật.';
    end if;
    update materials
      set ten = v_ten, dvt = v_dvt, nhom = v_nhom, trang_thai = v_status,
          ma_vat_tu = coalesce(v_ma, ma_vat_tu)
      where id = v_id
      returning * into v_row;
    perform write_audit(v_actor, 'UPDATE_MATERIAL', 'materials', v_row.id::text, v_before, to_jsonb(v_row), 'OK', '');
  end if;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'ma', v_row.ma_vat_tu);
end;
$$;

-- Insert or update a supplier / counterparty. Payload:
--   { "id": uuid|null, "ten": "...", "maDoiTuong": "DT-0007"|null (auto if blank on insert),
--     "loai": "NCC", "mst": "...", "diaChi": "...", "contact": "...", "sdt": "...",
--     "dieuKhoan": "...", "moq": "...", "trangThai": "Hoạt động"|"Ngừng" }
create or replace function rpc_upsert_doi_tuong(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor   profiles;
  v_id      uuid := nullif(p_payload->>'id','')::uuid;
  v_ten     text := nullif(trim(coalesce(p_payload->>'ten','')), '');
  v_ma      text := nullif(trim(coalesce(p_payload->>'maDoiTuong','')), '');
  v_loai    text := coalesce(nullif(trim(coalesce(p_payload->>'loai','')),''), 'NCC');
  v_status  text := coalesce(nullif(trim(coalesce(p_payload->>'trangThai','')),''), 'Hoạt động');
  v_before  jsonb;
  v_row     doi_tuong;
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then
    raise exception 'Cần nhập tên nhà cung cấp / đối tượng.';
  end if;

  if exists (
    select 1 from doi_tuong
    where normalize_text(ten_doi_tuong) = normalize_text(v_ten)
      and (v_id is null or id <> v_id)
  ) then
    raise exception 'Đối tượng "%" đã tồn tại.', v_ten;
  end if;
  if v_ma is not null and exists (
    select 1 from doi_tuong where ma_doi_tuong = v_ma and (v_id is null or id <> v_id)
  ) then
    raise exception 'Mã đối tượng "%" đã được dùng.', v_ma;
  end if;

  if v_id is null then
    insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, dia_chi, contact, sdt, dieu_khoan_tt_mac_dinh, moq, trang_thai)
    values (
      coalesce(v_ma, next_code('DT')), v_ten, v_loai,
      nullif(trim(coalesce(p_payload->>'mst','')),''),
      nullif(trim(coalesce(p_payload->>'diaChi','')),''),
      nullif(trim(coalesce(p_payload->>'contact','')),''),
      nullif(trim(coalesce(p_payload->>'sdt','')),''),
      nullif(trim(coalesce(p_payload->>'dieuKhoan','')),''),
      nullif(trim(coalesce(p_payload->>'moq','')),''),
      v_status
    )
    returning * into v_row;
    perform write_audit(v_actor, 'CREATE_DOI_TUONG', 'doi_tuong', v_row.id::text, null, to_jsonb(v_row), 'OK', '');
  else
    select to_jsonb(d) into v_before from doi_tuong d where id = v_id;
    if v_before is null then
      raise exception 'Không tìm thấy đối tượng để cập nhật.';
    end if;
    update doi_tuong set
        ma_doi_tuong = coalesce(v_ma, ma_doi_tuong),
        ten_doi_tuong = v_ten,
        loai = v_loai,
        mst = nullif(trim(coalesce(p_payload->>'mst','')),''),
        dia_chi = nullif(trim(coalesce(p_payload->>'diaChi','')),''),
        contact = nullif(trim(coalesce(p_payload->>'contact','')),''),
        sdt = nullif(trim(coalesce(p_payload->>'sdt','')),''),
        dieu_khoan_tt_mac_dinh = nullif(trim(coalesce(p_payload->>'dieuKhoan','')),''),
        moq = nullif(trim(coalesce(p_payload->>'moq','')),''),
        trang_thai = v_status
      where id = v_id
      returning * into v_row;
    perform write_audit(v_actor, 'UPDATE_DOI_TUONG', 'doi_tuong', v_row.id::text, v_before, to_jsonb(v_row), 'OK', '');
  end if;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'ma', v_row.ma_doi_tuong);
end;
$$;

grant execute on function rpc_list_catalog() to authenticated;
grant execute on function rpc_upsert_material(jsonb) to authenticated;
grant execute on function rpc_upsert_doi_tuong(jsonb) to authenticated;
