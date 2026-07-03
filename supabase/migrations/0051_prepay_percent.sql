-- ============================================================================
-- 0051_prepay_percent.sql  (Đợt C)
--  * proposals.prepay_percent: % trả trước; hiện % + số tiền trên phiếu.
--  * Ràng buộc: phiếu Mua hàng >=2 mặt hàng cần >=2 báo giá đính kèm.
-- ============================================================================

alter table proposals add column if not exists prepay_percent numeric;

create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status','Nháp')='Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_loai text := case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end;
  v_in_plan boolean := coalesce((p_payload->>'trongKeHoachTuan')::boolean,false);
  v_giai_trinh text := nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),'');
  v_actor profiles; v_dt doi_tuong; v_ma text; v_pid uuid; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0; v_h jsonb;
begin
  v_actor := require_permission(case when v_status='Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines')=0 then raise exception 'Đề xuất cần ít nhất một dòng vật tư.'; end if;
  if v_status='Chờ duyệt' and not v_in_plan and v_giai_trinh is null then raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.'; end if;
  if v_status='Chờ duyệt' and v_loai='MuaHang' and jsonb_array_length(p_payload->'lines') >= 2
     and coalesce(jsonb_array_length(p_payload->'attachments'),0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;
  v_dt := ensure_doi_tuong(p_payload->'doiTuong'->>'ma', p_payload->'doiTuong'->>'ten', coalesce(p_payload->'doiTuong'->>'loai','NCC'),
    p_payload->'doiTuong'->>'mst', p_payload->'doiTuong'->>'diaChi', p_payload->'doiTuong'->>'contact', coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  v_ma := next_code('DX');
  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, doi_tuong_id, ten_doi_tuong, noi_dung,
    dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan, giai_trinh_ngoai_ke_hoach,
    han_thanh_toan, ton_kho, truong_bp_duyet, prepay, prepay_percent, attachments)
  values (v_ma, coalesce((p_payload->>'ngayDeXuat')::date, current_date), coalesce(p_payload->>'nguoiDeNghi', v_actor.name),
    p_payload->>'boPhan', v_dt.id, v_dt.ten_doi_tuong, p_payload->>'noiDung',
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
  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai) into v_h from proposals where id=v_pid;
  perform write_audit(v_actor,'CREATE_PROPOSAL','proposals',v_ma,null,v_h,'OK',v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma, 'status', v_status);
end; $$;

create or replace function rpc_update_proposal(p_ma_de_xuat text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_dt doi_tuong; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ sửa được phiếu Nháp.'; end if;
  v_dt := ensure_doi_tuong(null, p_payload->'doiTuong'->>'ten', 'NCC', null, null, null, coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  update proposals set
    loai_de_xuat = case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end,
    ngay_de_xuat = coalesce((p_payload->>'ngayDeXuat')::date, ngay_de_xuat),
    nguoi_de_nghi = coalesce(p_payload->>'nguoiDeNghi', nguoi_de_nghi), bo_phan = p_payload->>'boPhan',
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
    'NgayDeXuat', to_char(v_p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', v_p.nguoi_de_nghi, 'BoPhan', v_p.bo_phan,
    'TenDoiTuong', v_p.ten_doi_tuong, 'DieuKhoanTT', v_p.dieu_khoan_tt, 'HanThanhToan', to_char(v_p.han_thanh_toan,'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho, 'TruongBpDuyet', v_p.truong_bp_duyet, 'Prepay', v_p.prepay, 'PrepayPercent', v_p.prepay_percent, 'LyDoTraLai', v_p.ly_do_tra_lai,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach, 'Attachments', v_p.attachments,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('matHang', l.mat_hang, 'slDat', l.sl_dat, 'donGia', l.don_gia_chua_vat, 'vat', (l.vat_rate*100)||'%', 'ghiChu', l.ghi_chu) order by l.ma_line),'[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id))
  into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

create or replace function rpc_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('recent:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;

  select jsonb_build_object(
    'MaDeXuat', v_p.ma_de_xuat,
    'LoaiDeXuat', v_p.loai_de_xuat,
    'TrangThai', v_p.trang_thai,
    'BoPhan', v_p.bo_phan,
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

create or replace function rpc_oversight_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('oversight:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_actor.role = 'TruongPhong' and (v_actor.bo_phan is null or v_p.bo_phan is distinct from v_actor.bo_phan) then
    raise exception 'Trưởng bộ phận chỉ xem được phiếu thuộc bộ phận mình.';
  end if;

  select jsonb_build_object(
    'MaDeXuat', v_p.ma_de_xuat,
    'LoaiDeXuat', v_p.loai_de_xuat,
    'TrangThai', v_p.trang_thai,
    'BoPhan', v_p.bo_phan,
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
  if v_p.loai_de_xuat = 'MuaHang'
     and (select count(*) from proposal_lines where proposal_id = v_p.id) >= 2
     and coalesce(jsonb_array_length(v_p.attachments), 0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;
  update proposals set trang_thai = 'Chờ duyệt', ly_do_tra_lai = null where id = v_p.id;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

grant execute on function rpc_submit_proposal(text) to authenticated;
grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_update_proposal(text, jsonb) to authenticated;
grant execute on function rpc_get_proposal(text) to authenticated;
grant execute on function rpc_proposal_detail(text) to authenticated;
grant execute on function rpc_oversight_proposal_detail(text) to authenticated;
