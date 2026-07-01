-- ============================================================================
-- 0021_rpc_groups_bank_acceptance.sql
-- RPC updates for: dynamic material groups, supplier bank info, and the
-- goods-acceptance (nghiệm thu) step on the receipt screen.
-- ============================================================================

-- ---- Catalog: groups from table + supplier bank fields ---------------------
create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_materials jsonb; v_suppliers jsonb; v_groups jsonb;
begin
  perform require_permission('catalog:read');

  select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb) into v_groups from material_groups;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_vat_tu, 'ten', ten, 'dvt', dvt,
      'nhom', nhom, 'trangThai', trang_thai
    ) order by nhom nulls last, ten), '[]'::jsonb)
  into v_materials from materials;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'ma', ma_doi_tuong, 'ten', ten_doi_tuong, 'loai', loai,
      'mst', mst, 'diaChi', dia_chi, 'contact', contact, 'sdt', sdt,
      'dieuKhoan', dieu_khoan_tt_mac_dinh, 'moq', moq,
      'soTk', so_tk_ngan_hang, 'chiNhanh', chi_nhanh_ngan_hang,
      'trangThai', trang_thai
    ) order by ten_doi_tuong), '[]'::jsonb)
  into v_suppliers from doi_tuong;

  return jsonb_build_object('ok', true, 'groups', v_groups, 'materials', v_materials, 'suppliers', v_suppliers);
end;
$$;

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
  if v_ten is null then raise exception 'Cần nhập tên nhà cung cấp / đối tượng.'; end if;

  if exists (select 1 from doi_tuong where normalize_text(ten_doi_tuong) = normalize_text(v_ten) and (v_id is null or id <> v_id)) then
    raise exception 'Đối tượng "%" đã tồn tại.', v_ten;
  end if;
  if v_ma is not null and exists (select 1 from doi_tuong where ma_doi_tuong = v_ma and (v_id is null or id <> v_id)) then
    raise exception 'Mã đối tượng "%" đã được dùng.', v_ma;
  end if;

  if v_id is null then
    insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, dia_chi, contact, sdt, dieu_khoan_tt_mac_dinh, moq, so_tk_ngan_hang, chi_nhanh_ngan_hang, trang_thai)
    values (
      coalesce(v_ma, next_code('DT')), v_ten, v_loai,
      nullif(trim(coalesce(p_payload->>'mst','')),''),
      nullif(trim(coalesce(p_payload->>'diaChi','')),''),
      nullif(trim(coalesce(p_payload->>'contact','')),''),
      nullif(trim(coalesce(p_payload->>'sdt','')),''),
      nullif(trim(coalesce(p_payload->>'dieuKhoan','')),''),
      nullif(trim(coalesce(p_payload->>'moq','')),''),
      nullif(trim(coalesce(p_payload->>'soTk','')),''),
      nullif(trim(coalesce(p_payload->>'chiNhanh','')),''),
      v_status
    ) returning * into v_row;
    perform write_audit(v_actor, 'CREATE_DOI_TUONG', 'doi_tuong', v_row.id::text, null, to_jsonb(v_row), 'OK', '');
  else
    select to_jsonb(d) into v_before from doi_tuong d where id = v_id;
    if v_before is null then raise exception 'Không tìm thấy đối tượng để cập nhật.'; end if;
    update doi_tuong set
        ma_doi_tuong = coalesce(v_ma, ma_doi_tuong),
        ten_doi_tuong = v_ten, loai = v_loai,
        mst = nullif(trim(coalesce(p_payload->>'mst','')),''),
        dia_chi = nullif(trim(coalesce(p_payload->>'diaChi','')),''),
        contact = nullif(trim(coalesce(p_payload->>'contact','')),''),
        sdt = nullif(trim(coalesce(p_payload->>'sdt','')),''),
        dieu_khoan_tt_mac_dinh = nullif(trim(coalesce(p_payload->>'dieuKhoan','')),''),
        moq = nullif(trim(coalesce(p_payload->>'moq','')),''),
        so_tk_ngan_hang = nullif(trim(coalesce(p_payload->>'soTk','')),''),
        chi_nhanh_ngan_hang = nullif(trim(coalesce(p_payload->>'chiNhanh','')),''),
        trang_thai = v_status
      where id = v_id returning * into v_row;
    perform write_audit(v_actor, 'UPDATE_DOI_TUONG', 'doi_tuong', v_row.id::text, v_before, to_jsonb(v_row), 'OK', '');
  end if;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'ma', v_row.ma_doi_tuong);
end;
$$;

-- Add / rename a material group (nhóm hàng). Rename also re-tags materials.
create or replace function rpc_add_material_group(p_ten text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ten text := nullif(trim(coalesce(p_ten,'')),'');
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then raise exception 'Cần nhập tên nhóm hàng.'; end if;
  insert into material_groups (ten) values (v_ten) on conflict (ten) do nothing;
  return jsonb_build_object('ok', true, 'groups', (select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb) from material_groups));
end;
$$;

create or replace function rpc_rename_material_group(p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_old text := trim(coalesce(p_old,'')); v_new text := nullif(trim(coalesce(p_new,'')),'');
begin
  v_actor := require_permission('catalog:manage');
  if v_new is null then raise exception 'Tên nhóm mới không được trống.'; end if;
  if exists (select 1 from material_groups where ten = v_new) then raise exception 'Nhóm "%" đã tồn tại.', v_new; end if;
  update material_groups set ten = v_new where ten = v_old;
  update materials set nhom = v_new where nhom = v_old;
  return jsonb_build_object('ok', true, 'groups', (select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb) from material_groups));
end;
$$;

-- ---- Nghiệm thu (goods acceptance) -----------------------------------------
-- Approved obligations still awaiting acceptance, with proposal + amounts so the
-- buyer can find and finalize their own item.
create or replace function rpc_get_open_receipt_items(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('receipt:update');
  select coalesce(jsonb_agg(row_data order by (row_data->>'NgayDuyet') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'MaCN', d.ma_cn,
      'MaDeXuat', p.ma_de_xuat,
      'MaDoiTuong', dt.ma_doi_tuong,
      'TenDoiTuong', d.ten_doi_tuong,
      'MatHang', d.mat_hang,
      'SLDat', d.sl_dat,
      'DonGia', d.don_gia,
      'VATRate', d.vat_rate,
      'ThanhTienDat', round(coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate), 2),
      'NguoiDeNghi', p.nguoi_de_nghi,
      'DieuKhoanTT', d.dieu_khoan_tt,
      'NgayDuyet', to_char(d.ngay_duyet, 'YYYY-MM-DD')
    ) as row_data
    from debts d
    left join proposals p on p.id = d.proposal_id
    left join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false and d.sl_thuc_nhan is null
    order by d.created_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ma_cn text := trim(coalesce(p_payload->>'maCN', ''));
  v_qty numeric;
  v_before debts; v_after debts;
begin
  v_actor := require_permission('receipt:update');
  if v_ma_cn = '' then raise exception 'Cần chọn Mã CN/ĐX cần nghiệm thu.'; end if;
  v_qty := parse_number(p_payload->>'slThucNhan');
  if v_qty is null then raise exception 'Cần nhập SL thực nhận (khối lượng nghiệm thu).'; end if;

  select * into v_before from debts where ma_cn = v_ma_cn;
  if v_before is null then raise exception 'Không tìm thấy mã công nợ %.', v_ma_cn; end if;

  update debts set
    sl_thuc_nhan = v_qty,
    ngay_nhan = coalesce((p_payload->>'ngayNhan')::date, current_date),
    ma_chung_tu = coalesce(nullif(trim(coalesce(p_payload->>'chungTu','')),''), ma_chung_tu),
    ho_so_day_du = coalesce((p_payload->>'hoSoDayDu')::boolean, false),
    nghiem_thu_at = now(),
    nghiem_thu_by = v_actor.id,
    ghi_chu = case when coalesce(trim(p_payload->>'ghiChu'), '') <> ''
      then coalesce(ghi_chu || ' | ', '') || 'Nghiệm thu: ' || (p_payload->>'ghiChu') else ghi_chu end
  where id = v_before.id returning * into v_after;

  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', '');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end;
$$;

grant execute on function rpc_list_catalog() to authenticated;
grant execute on function rpc_upsert_doi_tuong(jsonb) to authenticated;
grant execute on function rpc_add_material_group(text) to authenticated;
grant execute on function rpc_rename_material_group(text, text) to authenticated;
grant execute on function rpc_get_open_receipt_items(int) to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
