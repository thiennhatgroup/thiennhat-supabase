-- ============================================================================
-- 0062_cashier_ux_and_vat.sql
--  * Nghiệm thu: NVMH bắt buộc nhập SỐ HÓA ĐƠN VAT (cùng STK + chi nhánh NH) —
--    đủ mọi trường mà phiếu YCTT cần.
--  * rpc_get_debt_detail: thêm dấu vết truy xuất (KTTH duyệt ai/lúc nào, đề xuất
--    lúc nào, sếp duyệt lúc nào) + số HĐ VAT.
--  * Thủ quỹ chi: thêm HÌNH THỨC (CK / Tiền mặt) — tiền mặt đính kèm phiếu chi.
--  * Cấp quyền Thủ quỹ XEM: Theo dõi công nợ + Duyệt hồ sơ thanh toán (như KTTH).
-- ============================================================================

alter table debts add column if not exists so_hoa_don_vat text;

insert into role_permissions (role, permission) values
  ('ThuQuy', 'dashboard:read'), ('ThuQuy', 'congno:confirm'), ('ThuQuy', 'receipt:review')
on conflict (role, permission) do nothing;

-- ---- Nghiệm thu: bắt buộc STK + chi nhánh NH + SỐ HÓA ĐƠN VAT ---------------
create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ma_cn text := trim(coalesce(p_payload->>'maCN','')); v_qty numeric;
  v_before debts; v_after debts; v_nguoi text; v_tong numeric; v_msg text;
  v_stk text := nullif(trim(coalesce(p_payload->>'soTk','')),''); v_cn text := nullif(trim(coalesce(p_payload->>'chiNhanh','')),'');
  v_hd text := nullif(trim(coalesce(p_payload->>'soHoaDon','')),'');
begin
  v_actor := require_permission('receipt:update');
  if v_ma_cn = '' then raise exception 'Cần chọn Mã CN/ĐX cần nghiệm thu.'; end if;
  v_qty := parse_number(p_payload->>'slThucNhan');
  if v_qty is null then raise exception 'Cần nhập SL thực nhận (khối lượng nghiệm thu).'; end if;
  if v_stk is null then raise exception 'Bắt buộc nhập Số tài khoản NCC.'; end if;
  if v_cn is null then raise exception 'Bắt buộc nhập Chi nhánh ngân hàng NCC.'; end if;
  if v_hd is null then raise exception 'Bắt buộc nhập Số hóa đơn VAT.'; end if;
  select * into v_before from debts where ma_cn = v_ma_cn;
  if v_before is null then raise exception 'Không tìm thấy mã công nợ %.', v_ma_cn; end if;
  update debts set
    sl_thuc_nhan = v_qty,
    ngay_nhan = coalesce((p_payload->>'ngayNhan')::date, current_date),
    ma_chung_tu = coalesce(nullif(trim(coalesce(p_payload->>'chungTu','')),''), ma_chung_tu),
    so_hoa_don_vat = v_hd,
    han_thanh_toan = coalesce((p_payload->>'hanThanhToan')::date, han_thanh_toan),
    chung_tu_types = coalesce(p_payload->'chungTuTypes', '[]'::jsonb),
    nghiem_thu_files = coalesce(p_payload->'files', nghiem_thu_files),
    ho_so_day_du = (jsonb_array_length(coalesce(p_payload->'chungTuTypes','[]'::jsonb)) > 0),
    cho_bo_sung = false, ly_do_bo_sung = null,
    nghiem_thu_at = now(), nghiem_thu_by = v_actor.id,
    ghi_chu = case when coalesce(trim(p_payload->>'ghiChu'),'') <> '' then coalesce(ghi_chu||' | ','') || 'Nghiệm thu: ' || (p_payload->>'ghiChu') else ghi_chu end
  where id = v_before.id returning * into v_after;

  if v_after.doi_tuong_id is not null then
    update doi_tuong set so_tk_ngan_hang = v_stk, chi_nhanh_ngan_hang = v_cn where id = v_after.doi_tuong_id;
  end if;

  select nguoi_de_nghi into v_nguoi from proposals where id = v_after.proposal_id;
  v_tong := round(coalesce(v_after.sl_thuc_nhan,0) * v_after.don_gia * (1 + v_after.vat_rate), 0);
  v_msg := v_ma_cn || ' — ' || coalesce(v_after.ten_doi_tuong,'')
           || case when coalesce(v_after.mat_hang,'') <> '' then ' · ' || v_after.mat_hang else '' end
           || ' · ' || to_char(v_tong,'FM999,999,999') || 'đ'
           || case when coalesce(v_nguoi,'') <> '' then ' · Đề nghị: ' || v_nguoi else '' end;

  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'receipt_review', 'Đơn chờ duyệt chứng từ & lưu công nợ', v_msg, 'congnoconfirm', v_ma_cn
  from profiles where role in ('KeToanCongNo','Admin') and status = 'Hoạt động';

  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', 'Chờ kế toán duyệt hồ sơ.');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end; $$;
grant execute on function rpc_update_receipt(jsonb) to authenticated;

-- ---- Chi tiết khoản: thêm dấu vết truy xuất + số HĐ VAT ---------------------
create or replace function rpc_get_debt_detail(p_ma_cn text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_j jsonb;
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập.'; end if;
  select jsonb_build_object(
    'maCN', vd.ma_cn, 'maDeXuat', p.ma_de_xuat, 'tenDoiTuong', vd.ten_doi_tuong,
    'boPhan', p.bo_phan, 'nguoiDeNghi', p.nguoi_de_nghi,
    'matHang', vd.mat_hang, 'dvt', (select dvt from materials m where m.id = vd.material_id),
    'slDat', vd.sl_dat, 'slThucNhan', vd.sl_thuc_nhan, 'donGia', vd.don_gia, 'vatRate', vd.vat_rate,
    'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', vd.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
    'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'ngayNhan', to_char(vd.ngay_nhan,'YYYY-MM-DD'),
    'dieuKhoanTT', vd.dieu_khoan_tt, 'trangThai', vd.trang_thai_dong,
    'soHoaDonVat', d.so_hoa_don_vat,
    'chungTuTypes', coalesce(vd.chung_tu_types,'[]'::jsonb),
    'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb), 'baoGia', coalesce(p.attachments,'[]'::jsonb),
    'soTk', dt.so_tk_ngan_hang, 'chiNhanh', dt.chi_nhanh_ngan_hang, 'mst', dt.mst,
    -- Dấu vết truy xuất
    'thoiGianDeXuat', to_char(p.created_at,'YYYY-MM-DD HH24:MI'),
    'thoiGianSepDuyet', to_char(p.approved_at,'YYYY-MM-DD HH24:MI'),
    'nguoiSepDuyet', (select name from profiles where id = p.nguoi_duyet),
    'nguoiNghiemThu', (select name from profiles where id = d.nghiem_thu_by),
    'thoiGianNghiemThu', to_char(d.nghiem_thu_at,'YYYY-MM-DD HH24:MI'),
    'ktthDuyet', (select name from profiles where id = d.cong_no_confirmed_by),
    'thoiGianKtthDuyet', to_char(d.cong_no_confirmed_at,'YYYY-MM-DD HH24:MI')
  ) into v_j
  from v_debts vd
  join debts d on d.id = vd.id
  left join doi_tuong dt on dt.id = vd.doi_tuong_id
  left join proposals p on p.id = d.proposal_id
  where vd.ma_cn = trim(coalesce(p_ma_cn,''));
  if v_j is null then raise exception 'Không tìm thấy khoản %.', p_ma_cn; end if;
  return jsonb_build_object('ok', true, 'debt', v_j);
end; $$;
grant execute on function rpc_get_debt_detail(text) to authenticated;

-- ---- Thủ quỹ chi 1 khoản: thêm hình thức (CK / Tiền mặt) --------------------
drop function if exists rpc_cashier_pay_line(uuid, jsonb, numeric);
create or replace function rpc_cashier_pay_line(p_line_id uuid, p_proof jsonb default '[]'::jsonb, p_amount numeric default null, p_hinh_thuc text default 'CK')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_line payment_request_lines; v_pr payment_requests;
  v_dt doi_tuong; v_ma_cn text; v_ma_tt text; v_pay_id uuid; v_creator uuid; v_ma_dx text;
  v_remaining int; v_amt numeric; v_du numeric; v_ht text;
begin
  v_actor := require_permission('payment:execute');
  v_ht := case when p_hinh_thuc = 'Tiền mặt' then 'Tiền mặt' else 'CK' end;
  select * into v_line from payment_request_lines where id = p_line_id for update;
  if v_line is null then raise exception 'Không tìm thấy khoản chi.'; end if;
  if v_line.paid then raise exception 'Khoản này đã được xác nhận chuyển rồi.'; end if;
  select * into v_pr from payment_requests where id = v_line.request_id;
  if v_pr.trang_thai <> 'Đã duyệt' then
    raise exception 'Chỉ chuyển tiền sau khi đề xuất % đã được lãnh đạo DUYỆT.', v_pr.ma_de_xuat_tt;
  end if;
  v_amt := coalesce(p_amount, v_line.so_tien);
  if v_amt <= 0 then raise exception 'Số tiền đã chuyển phải > 0.'; end if;

  v_ma_cn := null; v_creator := null; v_ma_dx := null;
  if v_line.debt_id is not null then
    select ma_cn into v_ma_cn from debts where id = v_line.debt_id;
    select p.nguoi_tao, p.ma_de_xuat into v_creator, v_ma_dx
      from debts d left join proposals p on p.id = d.proposal_id where d.id = v_line.debt_id;
    select so_tien_con_lai into v_du from v_debts where id = v_line.debt_id;
    if round(v_amt) > round(coalesce(v_du,0)) + 1 then
      raise exception 'Số tiền đã chuyển (% đ) VƯỢT số dư còn lại (% đ) của khoản %. Kiểm tra lại.',
        to_char(v_amt,'FM999,999,999'), to_char(coalesce(v_du,0),'FM999,999,999'), v_ma_cn;
    end if;
  end if;
  if v_line.doi_tuong_id is not null then select * into v_dt from doi_tuong where id = v_line.doi_tuong_id;
  else v_dt := ensure_doi_tuong(null, v_line.ncc, 'NCC', null, null, null, null); end if;

  v_ma_tt := next_code('TT');
  insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai, proof_files)
  values (v_ma_tt, current_date, v_dt.id, v_dt.ten_doi_tuong, v_amt,
          case when v_line.debt_id is not null then 'MA_CN' else 'FIFO' end,
          v_ma_cn, null, format('Chi %s theo ĐXTT %s | %s', v_ht, v_pr.ma_de_xuat_tt, coalesce(v_line.noi_dung,'')), v_actor.id, 'Đã ghi nhận',
          coalesce(p_proof, '[]'::jsonb))
  returning id into v_pay_id;

  if v_line.debt_id is not null then
    insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
    values (v_pay_id, v_line.debt_id, v_ma_cn, v_amt);
    update debts set da_thanh_toan = da_thanh_toan + v_amt, ngay_tt_cuoi = current_date where id = v_line.debt_id;
    if v_creator is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (v_creator, 'payment_done', 'Khoản của bạn đã được chuyển tiền',
              coalesce(v_ma_dx,'') || ' · ' || coalesce(v_ma_cn,'') || ' · ' || to_char(v_amt,'FM999,999,999') || 'đ (' || v_ht || ', thủ quỹ: ' || coalesce(v_actor.name,'') || ')',
              'proposal', coalesce(v_ma_dx, v_ma_cn));
    end if;
  end if;

  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'payment_done', 'Thủ quỹ đã chi 1 khoản',
         v_pr.ma_de_xuat_tt || ' · ' || coalesce(v_ma_cn, v_line.ncc, '') || ' · ' || to_char(v_amt,'FM999,999,999') || 'đ (' || v_ht || ')',
         'debtpay', v_pr.ma_de_xuat_tt
  from profiles where role in ('KeToanCongNo','Admin') and status = 'Hoạt động';

  update payment_request_lines set paid = true, paid_at = now(), proof_files = coalesce(p_proof,'[]'::jsonb),
    so_tien_da_chuyen = v_amt, hinh_thuc_tt = v_ht where id = v_line.id;

  select count(*) into v_remaining from payment_request_lines where request_id = v_pr.id and paid = false;
  if v_remaining = 0 then update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id; end if;

  perform write_audit(v_actor, 'CASHIER_PAY_LINE', 'payment_request_lines', v_line.id::text, to_jsonb(v_line),
    jsonb_build_object('amount', v_amt, 'hinhThuc', v_ht, 'remaining', v_remaining), 'OK', 'Thủ quỹ xác nhận chi 1 khoản.');
  return jsonb_build_object('ok', true, 'maDeXuatTT', v_pr.ma_de_xuat_tt, 'remaining', v_remaining);
end; $$;
grant execute on function rpc_cashier_pay_line(uuid, jsonb, numeric, text) to authenticated;
