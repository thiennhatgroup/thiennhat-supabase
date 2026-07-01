-- ============================================================================
-- 0008_rpc_receipts_payments.sql
-- rpc_get_open_receipt_items()  mirrors apiGetOpenReceiptItems()
-- rpc_update_receipt()          mirrors apiUpdateReceipt()
-- rpc_create_payment()          mirrors apiCreatePayment() + allocatePaymentToCongNo_()
--                                + appendAdvancePaymentRow_()
--
-- FIFO ordering matches compareCongNoItemsForSettlement_(): sort by due date
-- (falling back to receive/approve/proposal date when due date is blank),
-- then by that same date again, then by insertion order.
-- ============================================================================

create or replace function rpc_get_open_receipt_items(p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('receipt:update');
  select coalesce(jsonb_agg(row_data), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'MaCN', ma_cn, 'MaDoiTuong', (select ma_doi_tuong from doi_tuong where id = doi_tuong_id),
      'TenDoiTuong', ten_doi_tuong, 'MatHang', mat_hang, 'SLDat', sl_dat,
      'NgayDeXuat', to_char(ngay_de_xuat, 'YYYY-MM-DD'), 'NgayDuyet', to_char(ngay_duyet, 'YYYY-MM-DD')
    ) as row_data
    from debts
    where is_archived = false and (sl_thuc_nhan is null)
    order by created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 300)
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
  v_before debts;
  v_after debts;
begin
  v_actor := require_permission('receipt:update');
  if v_ma_cn = '' then
    raise exception 'Cần chọn Mã CN/ĐX.';
  end if;
  v_qty := parse_number(p_payload->>'slThucNhan');
  if v_qty is null then
    raise exception 'Cần nhập SL thực nhận.';
  end if;

  select * into v_before from debts where ma_cn = v_ma_cn;
  if v_before is null then
    raise exception 'Không tìm thấy mã công nợ %.', v_ma_cn;
  end if;

  update debts set
    sl_thuc_nhan = v_qty,
    ngay_nhan = coalesce((p_payload->>'ngayNhan')::date, current_date),
    ma_chung_tu = coalesce(p_payload->>'chungTu', ma_chung_tu),
    ghi_chu = case when coalesce(trim(p_payload->>'ghiChu'), '') <> ''
      then coalesce(ghi_chu || ' | ', '') || 'Nhận hàng: ' || (p_payload->>'ghiChu')
      else ghi_chu end
  where id = v_before.id
  returning * into v_after;

  perform write_audit(v_actor, 'UPDATE_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', '');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end;
$$;

create or replace function rpc_create_payment(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_amount numeric := parse_number(p_payload->>'soTien');
  v_mode text := coalesce(p_payload->>'phanBoMode', 'FIFO');
  v_ma_cn text := trim(coalesce(p_payload->>'maCN', ''));
  v_doi_tuong doi_tuong;
  v_ma_tt text;
  v_payment_id uuid;
  v_ngay date;
  v_remaining numeric;
  v_debt debts;
  v_gap numeric;
  v_applied numeric;
  v_allocation jsonb := '[]'::jsonb;
  v_advance_id uuid;
begin
  v_actor := require_permission('payment:create');
  if v_amount is null or v_amount <= 0 then
    raise exception 'Số tiền thanh toán phải lớn hơn 0.';
  end if;
  if v_mode not in ('FIFO', 'MA_CN') then
    v_mode := 'FIFO';
  end if;
  if v_mode = 'MA_CN' and v_ma_cn = '' then
    raise exception 'Bạn đã chọn phân bổ theo mã CN, cần nhập Mã CN cụ thể.';
  end if;

  v_doi_tuong := ensure_doi_tuong(
    p_payload->'doiTuong'->>'ma', p_payload->'doiTuong'->>'ten', coalesce(p_payload->'doiTuong'->>'loai', 'NCC'),
    null, null, null, null
  );
  v_ngay := coalesce((p_payload->>'ngayThanhToan')::date, current_date);
  v_ma_tt := next_code('TT');

  insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap)
  values (v_ma_tt, v_ngay, v_doi_tuong.id, v_doi_tuong.ten_doi_tuong, v_amount, v_mode, nullif(v_ma_cn, ''), p_payload->>'chungTu', p_payload->>'ghiChu', v_actor.id)
  returning id into v_payment_id;

  if v_mode = 'MA_CN' then
    select * into v_debt from debts where ma_cn = v_ma_cn and is_archived = false;
    if v_debt is null then
      raise exception 'Không tìm thấy Mã CN % để ghi thanh toán.', v_ma_cn;
    end if;
    update debts set da_thanh_toan = da_thanh_toan + v_amount, ngay_tt_cuoi = v_ngay where id = v_debt.id;
    insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo) values (v_payment_id, v_debt.id, v_debt.ma_cn, v_amount);
    v_allocation := jsonb_build_array(jsonb_build_object('maCN', v_ma_cn, 'applied', v_amount));
  else
    v_remaining := v_amount;
    -- FIFO across this counterparty's open, "receivable" obligations —
    -- mirrors compareCongNoItemsForSettlement_ ordering (due date first,
    -- falling back to the receive/approve/proposal date, then insertion order).
    for v_debt in
      select d.* from debts d
      join v_debts vd on vd.id = d.id
      where d.doi_tuong_id = v_doi_tuong.id
        and d.is_archived = false
        and vd.can_settle
        and vd.thanh_tien_thuc_nhan - d.da_thanh_toan > 0
      order by coalesce(d.han_thanh_toan, d.ngay_nhan, d.ngay_duyet, d.ngay_de_xuat) asc nulls last, d.created_at asc
    loop
      if v_remaining <= 0 then exit; end if;
      select thanh_tien_thuc_nhan into v_gap from v_debts where id = v_debt.id;
      v_gap := greatest(v_gap - v_debt.da_thanh_toan, 0);
      v_applied := least(v_gap, v_remaining);
      if v_applied > 0 then
        update debts set da_thanh_toan = da_thanh_toan + v_applied, ngay_tt_cuoi = v_ngay where id = v_debt.id;
        insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo) values (v_payment_id, v_debt.id, v_debt.ma_cn, v_applied);
        v_allocation := v_allocation || jsonb_build_array(jsonb_build_object('maCN', v_debt.ma_cn, 'applied', v_applied));
        v_remaining := round(v_remaining - v_applied, 2);
      end if;
    end loop;

    if v_remaining > 0 then
      -- No open obligation left to absorb the rest: park it as an advance,
      -- mirroring appendAdvancePaymentRow_().
      insert into debts (ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no, mat_hang, don_gia, vat_rate, da_thanh_toan, ngay_tt_cuoi, dieu_khoan_tt, ghi_chu, nguon_tao)
      values (
        next_code('TU'), v_ngay, v_ngay, v_doi_tuong.id, v_doi_tuong.ten_doi_tuong, 'TamUng',
        'Tạm ứng/trả trước chưa đối trừ', 0, 0, v_remaining, v_ngay,
        'Tạm ứng/trả trước tạo từ WebApp khi thanh toán vượt các khoản thực nhận đang mở.',
        p_payload->>'ghiChu', 'WebApp'
      )
      returning id into v_advance_id;
      insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
        select v_payment_id, v_advance_id, ma_cn, v_remaining from debts where id = v_advance_id;
      v_allocation := v_allocation || jsonb_build_array(jsonb_build_object('maCN', 'TAM_UNG', 'applied', v_remaining));
    end if;
  end if;

  perform write_audit(v_actor, 'CREATE_PAYMENT', 'payments', v_ma_tt, null, jsonb_build_object('soTien', v_amount, 'allocation', v_allocation), 'OK', '');
  return jsonb_build_object('ok', true, 'maThanhToan', v_ma_tt, 'allocation', jsonb_build_object('mode', v_mode, 'rows', v_allocation));
end;
$$;

grant execute on function rpc_get_open_receipt_items(int) to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
grant execute on function rpc_create_payment(jsonb) to authenticated;
