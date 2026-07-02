-- ============================================================================
-- 0035_record_debt_payment.sql — Ghi nhận thanh toán THEO TỪNG KHOẢN công nợ.
--   rpc_list_open_debts(ma?)      : liệt kê khoản còn phải trả (số dư > 0)
--   rpc_record_debt_payment(...)  : kế toán nhập số đã trả cho 1 khoản ->
--       tạo payment + allocation (bất biến) + cộng vào da_thanh_toan ->
--       số dư (so_tien_con_lai trong v_debts) tự cập nhật.
-- ============================================================================

create or replace function rpc_list_open_debts(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),''); v_rows jsonb;
begin
  perform require_permission('payment:create');
  select coalesce(jsonb_agg(x order by (x->>'hanThanhToan') nulls last), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maCN', vd.ma_cn, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', vd.ten_doi_tuong, 'matHang', vd.mat_hang,
      'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', vd.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
      'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'trangThai', vd.trang_thai_dong
    ) as x
    from v_debts vd join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false and vd.so_tien_con_lai > 0 and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

create or replace function rpc_record_debt_payment(p_ma_cn text, p_so_tien numeric, p_ngay date default null, p_chung_tu text default null, p_ghi_chu text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_debt debts; v_pay uuid; v_ngay date; v_ma_tt text;
begin
  v_actor := require_permission('payment:create');
  if p_so_tien is null or p_so_tien <= 0 then raise exception 'Số tiền đã trả phải lớn hơn 0.'; end if;
  select * into v_debt from debts where ma_cn = trim(coalesce(p_ma_cn,'')) and is_archived = false;
  if v_debt is null then raise exception 'Không tìm thấy khoản công nợ %.', p_ma_cn; end if;
  v_ngay := coalesce(p_ngay, current_date);
  v_ma_tt := next_code('TT');
  insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai)
  values (v_ma_tt, v_ngay, v_debt.doi_tuong_id, v_debt.ten_doi_tuong, p_so_tien, 'MA_CN', v_debt.ma_cn, p_chung_tu, p_ghi_chu, v_actor.id, 'Đã ghi nhận')
  returning id into v_pay;
  insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo) values (v_pay, v_debt.id, v_debt.ma_cn, p_so_tien);
  update debts set da_thanh_toan = da_thanh_toan + p_so_tien, ngay_tt_cuoi = v_ngay where id = v_debt.id;
  perform write_audit(v_actor, 'RECORD_DEBT_PAYMENT', 'debts', v_debt.ma_cn, to_jsonb(v_debt), jsonb_build_object('soTien', p_so_tien, 'maTT', v_ma_tt), 'OK', '');
  return jsonb_build_object('ok', true, 'maCN', v_debt.ma_cn, 'maThanhToan', v_ma_tt);
end; $$;

grant execute on function rpc_list_open_debts(text) to authenticated;
grant execute on function rpc_record_debt_payment(text, numeric, date, text, text) to authenticated;
