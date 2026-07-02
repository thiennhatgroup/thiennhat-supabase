-- ============================================================================
-- 0036_unify_payments.sql
-- #1 Thống nhất MỘT nguồn ghi thanh toán: "Cập nhật thanh toán" (per-debt) là
--    nơi DUY NHẤT ghi tiền vào công nợ. Nút "Đã chi tiền" ở đề xuất thanh toán
--    giờ chỉ ĐÁNH DẤU đề xuất là 'Đã chi' (không tự cộng da_thanh_toan) -> hết
--    rủi ro cộng đôi.
-- #2 Lịch sử thanh toán + hủy khoản ghi nhầm (trả lại da_thanh_toan).
-- ============================================================================

create or replace function rpc_execute_payment_request(p_ma text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests;
begin
  v_actor := require_permission('payment:execute');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Đã duyệt' then raise exception 'Chỉ đánh dấu đã chi khi đề xuất % đã được DUYỆT.', p_ma; end if;
  update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id;
  perform write_audit(v_actor, 'MARK_PAID_REQUEST', 'payment_requests', p_ma, to_jsonb(v_pr), null, 'OK',
    'Đánh dấu đã chi. Ghi số thực trả từng khoản ở màn "Cập nhật thanh toán".');
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma);
end; $$;

-- Lịch sử các lần thanh toán đã ghi (để đối chiếu / hủy nếu nhầm)
create or replace function rpc_list_payments(p_ma_doi_tuong text default null, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),''); v_rows jsonb;
begin
  perform require_permission('payment:create');
  select coalesce(jsonb_agg(x order by (x->>'createdAt') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maThanhToan', p.ma_thanh_toan, 'ngay', to_char(p.ngay_thanh_toan,'YYYY-MM-DD'), 'tenDoiTuong', p.ten_doi_tuong,
      'maCN', p.ma_cn, 'soTien', p.so_tien, 'ghiChu', p.ghi_chu,
      'nguoi', (select name from profiles where id = p.nguoi_nhap),
      'createdAt', to_char(p.created_at,'YYYY-MM-DD HH24:MI:SS')
    ) as x
    from payments p left join doi_tuong dt on dt.id = p.doi_tuong_id
    where (v_ma is null or dt.ma_doi_tuong = v_ma)
    order by p.created_at desc limit least(greatest(coalesce(p_limit,50),1),200)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- Hủy một lần thanh toán ghi nhầm: trả lại da_thanh_toan cho các khoản liên quan.
create or replace function rpc_delete_payment(p_ma_thanh_toan text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pay payments; r record;
begin
  v_actor := require_permission('payment:create');
  select * into v_pay from payments where ma_thanh_toan = trim(coalesce(p_ma_thanh_toan,''));
  if v_pay is null then raise exception 'Không tìm thấy lần thanh toán %.', p_ma_thanh_toan; end if;
  for r in select * from payment_allocations where payment_id = v_pay.id loop
    if r.debt_id is not null then
      update debts set da_thanh_toan = greatest(da_thanh_toan - r.so_tien_phan_bo, 0),
        is_archived = false, archived_at = null, archived_by = null
      where id = r.debt_id;
    end if;
  end loop;
  delete from payment_allocations where payment_id = v_pay.id;
  delete from payments where id = v_pay.id;
  perform write_audit(v_actor, 'DELETE_PAYMENT', 'payments', p_ma_thanh_toan, to_jsonb(v_pay), null, 'OK', 'Hủy khoản chi ghi nhầm.');
  return jsonb_build_object('ok', true, 'maThanhToan', p_ma_thanh_toan);
end; $$;

grant execute on function rpc_execute_payment_request(text) to authenticated;
grant execute on function rpc_list_payments(text, int) to authenticated;
grant execute on function rpc_delete_payment(text) to authenticated;
