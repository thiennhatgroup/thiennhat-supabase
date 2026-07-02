-- ============================================================================
-- 0029_rpc_attachments_flow.sql
-- Cập nhật RPC cho: trường mới (hạn TT, tồn kho, ghi chú lãnh đạo, attachments),
-- luồng nháp -> gửi duyệt, Chủ tịch override, nghiệm thu đính kèm + sửa hạn,
-- và đưa dữ liệu (báo giá, hạn TT, biên bản) sang màn kế toán.
-- ============================================================================

-- 1) Tạo đề xuất: nhận thêm hạn TT, tồn kho, ghi chú lãnh đạo, attachments
create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status', 'Nháp') = 'Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_loai text := case when coalesce(p_payload->>'loaiDeXuat','MuaHang') = 'TamUng' then 'TamUng' else 'MuaHang' end;
  v_in_plan boolean := coalesce((p_payload->>'trongKeHoachTuan')::boolean, false);
  v_giai_trinh text := nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')), '');
  v_actor profiles; v_doi_tuong doi_tuong; v_ma_de_xuat text; v_proposal_id uuid;
  v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_line_count int := 0; v_header jsonb;
begin
  v_actor := require_permission(case when v_status = 'Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines') = 0 then
    raise exception 'Đề xuất cần ít nhất một dòng vật tư.';
  end if;
  if v_status = 'Chờ duyệt' and not v_in_plan and v_giai_trinh is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần nhập giải trình trước khi gửi duyệt.';
  end if;

  v_doi_tuong := ensure_doi_tuong(
    p_payload->'doiTuong'->>'ma', p_payload->'doiTuong'->>'ten', coalesce(p_payload->'doiTuong'->>'loai', 'NCC'),
    p_payload->'doiTuong'->>'mst', p_payload->'doiTuong'->>'diaChi', p_payload->'doiTuong'->>'contact',
    coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  v_ma_de_xuat := next_code('DX');

  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, doi_tuong_id, ten_doi_tuong, noi_dung,
    dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan, giai_trinh_ngoai_ke_hoach,
    han_thanh_toan, ton_kho, note_lanh_dao, attachments)
  values (v_ma_de_xuat, coalesce((p_payload->>'ngayDeXuat')::date, current_date),
    coalesce(p_payload->>'nguoiDeNghi', v_actor.name), v_doi_tuong.id, v_doi_tuong.ten_doi_tuong,
    p_payload->>'noiDung', coalesce(p_payload->>'dieuKhoanTT', v_doi_tuong.dieu_khoan_tt_mac_dinh),
    v_status, v_actor.id, p_payload->>'ghiChu', v_loai, v_in_plan, v_giai_trinh,
    (p_payload->>'hanThanhToan')::date, parse_number(p_payload->>'tonKho'), p_payload->>'noteLanhDao',
    coalesce(p_payload->'attachments', '[]'::jsonb))
  returning id into v_proposal_id;

  for v_line in select * from jsonb_array_elements(p_payload->'lines')
  loop
    v_qty := parse_number(v_line->>'slDat'); v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'), '') = '' or v_qty is null or v_price is null then continue; end if;
    v_vat := parse_vat_rate(v_line->>'vat');
    perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (next_code('DXL'), v_proposal_id, trim(v_line->>'matHang'), v_qty, v_price, v_vat,
            round(v_qty * v_price * (1 + v_vat), 2), v_line->>'ghiChu', v_status);
    v_line_count := v_line_count + 1;
  end loop;
  if v_line_count = 0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;

  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai) into v_header from proposals where id = v_proposal_id;
  perform write_audit(v_actor, 'CREATE_PROPOSAL', 'proposals', v_ma_de_xuat, null, v_header, 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma_de_xuat, 'status', v_status);
end;
$$;

-- 2) Gửi duyệt 1 phiếu nháp (Nháp -> Chờ duyệt)
create or replace function rpc_submit_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals;
begin
  v_actor := require_permission('proposal:submit');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ gửi duyệt được phiếu đang ở trạng thái Nháp.'; end if;
  if not v_p.trong_ke_hoach_tuan and nullif(trim(coalesce(v_p.giai_trinh_ngoai_ke_hoach,'')),'') is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.';
  end if;
  update proposals set trang_thai = 'Chờ duyệt' where id = v_p.id;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

-- 3) Duyệt: mang hạn TT sang công nợ; Chủ tịch/Admin override mọi mức tiền
create or replace function rpc_approve_proposal(p_ma_de_xuat text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_proposal proposals; v_line proposal_lines; v_row_count int := 0;
  v_now date := current_date; v_new_debt_id uuid; v_total numeric; v_threshold numeric;
begin
  v_actor := require_permission('proposal:approve');
  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_proposal.trang_thai not in ('Chờ duyệt', 'Nháp') then raise exception 'Đề xuất % không ở trạng thái có thể duyệt.', p_ma_de_xuat; end if;
  select coalesce(sum(thanh_tien_sau_vat), 0) into v_total from proposal_lines where proposal_id = v_proposal.id;
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';
  if v_actor.role not in ('Admin','ChuTich') and v_total >= v_threshold then
    raise exception 'Khoản % đ (≥ %) thuộc thẩm quyền CHỦ TỊCH.', to_char(v_total,'FM999,999,999'), to_char(v_threshold,'FM999,999,999');
  end if;

  for v_line in select * from proposal_lines where proposal_id = v_proposal.id
  loop
    insert into debts (ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no,
      proposal_id, ma_lo_hang, mat_hang, sl_dat, don_gia, vat_rate, dieu_khoan_tt, han_thanh_toan, ghi_chu, nguon_tao)
    values (next_code('CN'), v_proposal.ngay_de_xuat, v_now, v_proposal.doi_tuong_id, v_proposal.ten_doi_tuong,
      case when v_proposal.loai_de_xuat = 'TamUng' then 'TamUng' else 'AP' end,
      v_proposal.id, p_ma_de_xuat || '-' || lpad((v_row_count + 1)::text, 2, '0'), v_line.mat_hang, v_line.sl_dat,
      v_line.don_gia_chua_vat, v_line.vat_rate, v_proposal.dieu_khoan_tt, v_proposal.han_thanh_toan,
      format('WebApp | Nội dung: %s | Ghi chú: %s', coalesce(v_proposal.noi_dung, ''), coalesce(v_line.ghi_chu, '')), 'WebApp')
    returning id into v_new_debt_id;
    v_row_count := v_row_count + 1;
    update proposal_lines set trang_thai = 'Đã duyệt', debt_id = v_new_debt_id where id = v_line.id;
  end loop;

  update proposals set trang_thai = 'Đã duyệt', nguoi_duyet = v_actor.id, approved_at = now(),
    ghi_chu = case when nullif(trim(coalesce(p_note,'')),'') is not null then coalesce(ghi_chu,'') || ' | Duyệt: ' || trim(p_note) else ghi_chu end
  where id = v_proposal.id;
  perform write_audit(v_actor, 'APPROVE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal), jsonb_build_object('rows', v_row_count, 'total', v_total), 'OK', coalesce(nullif(trim(p_note),''),'Đã duyệt.'));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'congNoRows', v_row_count);
end;
$$;

-- 4) Danh sách chờ duyệt: Chủ tịch/Admin thấy TẤT CẢ; TGĐ chỉ < ngưỡng. Trả kèm attachments/hạn/tồn kho/ghi chú.
create or replace function rpc_get_pending_proposals(p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_threshold numeric; v_rows jsonb;
begin
  v_actor := require_permission('proposal:approve');
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';
  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_rows
  from (
    select p.created_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'LoaiDeXuat', p.loai_de_xuat, 'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'TenDoiTuong', p.ten_doi_tuong, 'NoiDung', p.noi_dung, 'DieuKhoanTT', p.dieu_khoan_tt,
        'HanThanhToan', to_char(p.han_thanh_toan, 'YYYY-MM-DD'), 'TonKho', p.ton_kho, 'NoteLanhDao', p.note_lanh_dao,
        'NguoiDeNghi', p.nguoi_de_nghi, 'TrangThai', p.trang_thai, 'GhiChu', p.ghi_chu,
        'TrongKeHoachTuan', p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', p.giai_trinh_ngoai_ke_hoach,
        'Attachments', p.attachments,
        'TongTien', t.v_tong,
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('MaLine', l.ma_line, 'MatHang', l.mat_hang, 'SLDat', l.sl_dat,
            'DonGiaChuaVAT', l.don_gia_chua_vat, 'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id)
      ) as row_data
    from proposals p
    cross join lateral (select coalesce(sum(thanh_tien_sau_vat),0) as v_tong from proposal_lines where proposal_id = p.id) t
    where p.trang_thai = 'Chờ duyệt'
      and (v_actor.role in ('Admin','ChuTich')
           or (v_actor.role = 'TongGiamDoc' and t.v_tong < v_threshold)
           or v_actor.role not in ('ChuTich','TongGiamDoc','Admin'))
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- 5) Hủy duyệt: Chủ tịch/Admin mọi mức; TGĐ chỉ khoản < ngưỡng
create or replace function rpc_unapprove_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_proposal proposals; v_paid boolean; v_total numeric; v_threshold numeric;
begin
  v_actor := require_permission('proposal:approve');
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cần nhập lý do hủy duyệt để thông báo cho mua hàng.'; end if;
  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_proposal.trang_thai <> 'Đã duyệt' then raise exception 'Chỉ hủy duyệt được phiếu Đã duyệt.'; end if;
  select coalesce(sum(thanh_tien_sau_vat),0) into v_total from proposal_lines where proposal_id = v_proposal.id;
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';
  if v_actor.role not in ('Admin','ChuTich') and v_total >= v_threshold then
    raise exception 'Khoản ≥ % chỉ Chủ tịch mới được hủy duyệt.', to_char(v_threshold,'FM999,999,999');
  end if;
  select exists (select 1 from debts d where d.proposal_id = v_proposal.id
      and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))) into v_paid;
  if v_paid then raise exception 'Không thể hủy duyệt: đã có thanh toán ghi nhận trên công nợ của phiếu này.'; end if;
  update proposal_lines set trang_thai = 'Chờ duyệt', debt_id = null where proposal_id = v_proposal.id;
  delete from debts where proposal_id = v_proposal.id;
  update proposals set trang_thai = 'Từ chối', nguoi_duyet = v_actor.id, approved_at = now(),
    ghi_chu = coalesce(ghi_chu,'') || ' | HỦY DUYỆT: ' || trim(p_reason) where id = v_proposal.id;
  perform write_audit(v_actor, 'UNAPPROVE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal), jsonb_build_object('reason', p_reason), 'OK', trim(p_reason));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

-- 6) Danh sách đã duyệt theo ngày: trả kèm attachments + hạn TT
create or replace function rpc_get_approved_proposals(p_date date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_date date := coalesce(p_date, current_date); v_rows jsonb;
begin
  perform require_permission('proposal:approve');
  select coalesce(jsonb_agg(row_data order by approved_at desc), '[]'::jsonb) into v_rows
  from (
    select p.approved_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'LoaiDeXuat', p.loai_de_xuat, 'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD HH24:MI'), 'TenDoiTuong', p.ten_doi_tuong,
        'NoiDung', p.noi_dung, 'NguoiDeNghi', p.nguoi_de_nghi, 'NguoiDuyet', (select name from profiles where id = p.nguoi_duyet),
        'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'), 'Attachments', p.attachments,
        'TrongKeHoachTuan', p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', p.giai_trinh_ngoai_ke_hoach,
        'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0),
        'DaPhatSinhTT', exists (select 1 from debts d where d.proposal_id = p.id and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))),
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
            'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id)
      ) as row_data
    from proposals p
    where p.trang_thai = 'Đã duyệt' and p.approved_at is not null
      and (p.approved_at at time zone 'Asia/Ho_Chi_Minh')::date = v_date
    order by p.approved_at desc
  ) x;
  return jsonb_build_object('ok', true, 'date', to_char(v_date, 'YYYY-MM-DD'), 'rows', v_rows);
end;
$$;

-- 7) Nghiệm thu: thêm sửa hạn TT + đính kèm biên bản/phiếu cân
create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ma_cn text := trim(coalesce(p_payload->>'maCN', '')); v_qty numeric; v_before debts; v_after debts;
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
    han_thanh_toan = coalesce((p_payload->>'hanThanhToan')::date, han_thanh_toan),
    ho_so_day_du = coalesce((p_payload->>'hoSoDayDu')::boolean, false),
    nghiem_thu_files = coalesce(p_payload->'files', nghiem_thu_files),
    nghiem_thu_at = now(), nghiem_thu_by = v_actor.id,
    ghi_chu = case when coalesce(trim(p_payload->>'ghiChu'), '') <> '' then coalesce(ghi_chu || ' | ', '') || 'Nghiệm thu: ' || (p_payload->>'ghiChu') else ghi_chu end
  where id = v_before.id returning * into v_after;
  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', '');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end;
$$;

-- 8) Khoản chờ nghiệm thu: kèm báo giá gốc + hạn TT (để mua hàng đối chiếu)
create or replace function rpc_get_open_receipt_items(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('receipt:update');
  select coalesce(jsonb_agg(row_data order by (row_data->>'NgayDuyet') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'MaCN', d.ma_cn, 'MaDeXuat', p.ma_de_xuat, 'MaDoiTuong', dt.ma_doi_tuong, 'TenDoiTuong', d.ten_doi_tuong,
      'MatHang', d.mat_hang, 'SLDat', d.sl_dat, 'DonGia', d.don_gia, 'VATRate', d.vat_rate,
      'ThanhTienDat', round(coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate), 2),
      'NguoiDeNghi', p.nguoi_de_nghi, 'DieuKhoanTT', d.dieu_khoan_tt,
      'HanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD'), 'Attachments', coalesce(p.attachments,'[]'::jsonb),
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

-- 9) Khoản đến hạn cho kế toán: kèm hạn TT, biên bản nghiệm thu, báo giá gốc
create or replace function rpc_get_payable_debts(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),''); v_rows jsonb;
begin
  perform require_permission('payment:request');
  select coalesce(jsonb_agg(x order by (x->>'hanThanhToan') nulls first), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'debtId', vd.id, 'maCN', vd.ma_cn, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', vd.ten_doi_tuong,
      'matHang', vd.mat_hang, 'hanThanhToan', to_char(vd.han_thanh_toan, 'YYYY-MM-DD'), 'ngayDuyet', to_char(vd.ngay_duyet, 'YYYY-MM-DD'),
      'soDuConLai', vd.so_tien_con_lai, 'dieuKhoanTT', vd.dieu_khoan_tt, 'hoSoDayDu', vd.ho_so_day_du,
      'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb), 'baoGia', coalesce(p.attachments,'[]'::jsonb)
    ) as x
    from v_debts vd
    join doi_tuong dt on dt.id = vd.doi_tuong_id
    join debts d on d.id = vd.id
    left join proposals p on p.id = d.proposal_id
    where vd.is_archived = false and vd.so_tien_con_lai > 0 and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_submit_proposal(text) to authenticated;
grant execute on function rpc_approve_proposal(text, text) to authenticated;
grant execute on function rpc_get_pending_proposals(int) to authenticated;
grant execute on function rpc_unapprove_proposal(text, text) to authenticated;
grant execute on function rpc_get_approved_proposals(date) to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
grant execute on function rpc_get_open_receipt_items(int) to authenticated;
grant execute on function rpc_get_payable_debts(text) to authenticated;
