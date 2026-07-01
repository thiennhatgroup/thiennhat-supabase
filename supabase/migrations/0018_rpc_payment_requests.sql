-- ============================================================================
-- 0018_rpc_payment_requests.sql  (Redesign Đợt B)
-- RPCs for the payment-request document + its approval gate + governed
-- disbursement. All SECURITY DEFINER; permissions:
--   payment:request  (KeToanCongNo)  create / view own / execute after approval
--   payment:execute  (KeToanCongNo)  đi tiền sau khi đã duyệt
--   payment:approve  (LanhDao)       duyệt / từ chối
-- ============================================================================

-- Open AP obligations the accountant can pull into a request (hybrid source).
-- Uses v_debts so số dư còn lại is always computed, never stored-and-stale.
create or replace function rpc_get_payable_debts(p_ma_doi_tuong text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),'');
  v_rows jsonb;
begin
  perform require_permission('payment:request');
  select coalesce(jsonb_agg(x order by (x->>'hanThanhToan') nulls first), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'debtId', vd.id,
      'maCN', vd.ma_cn,
      'maDoiTuong', dt.ma_doi_tuong,
      'tenDoiTuong', vd.ten_doi_tuong,
      'matHang', vd.mat_hang,
      'hanThanhToan', to_char(vd.han_thanh_toan, 'YYYY-MM-DD'),
      'ngayDuyet', to_char(vd.ngay_duyet, 'YYYY-MM-DD'),
      'soDuConLai', vd.so_tien_con_lai,
      'dieuKhoanTT', vd.dieu_khoan_tt
    ) as x
    from v_debts vd
    join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false
      and vd.so_tien_con_lai > 0
      and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- Create a payment request (kế toán). status: 'Nháp' | 'Chờ duyệt'.
create or replace function rpc_create_payment_request(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_status text := case when coalesce(p_payload->>'status','Chờ duyệt') = 'Nháp' then 'Nháp' else 'Chờ duyệt' end;
  v_id uuid;
  v_ma text;
  v_line jsonb;
  v_debt debts;
  v_dt_id uuid;
  v_ncc text;
  v_sotien numeric;
  v_giaitrinh text;
  v_count int := 0;
begin
  v_actor := require_permission('payment:request');
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines') = 0 then
    raise exception 'Đề xuất thanh toán cần ít nhất một dòng.';
  end if;

  v_ma := next_code('PT');
  insert into payment_requests (ma_de_xuat_tt, ngay, nguoi_lap, trang_thai, ghi_chu)
  values (v_ma, coalesce((p_payload->>'ngay')::date, current_date), v_actor.id, v_status, p_payload->>'ghiChu')
  returning id into v_id;

  for v_line in select * from jsonb_array_elements(p_payload->'lines')
  loop
    v_sotien := parse_number(v_line->>'soTien');
    if v_sotien is null or v_sotien <= 0 then
      continue; -- bỏ qua dòng chưa nhập số tiền
    end if;
    v_giaitrinh := nullif(trim(coalesce(v_line->>'giaiTrinh','')),'');
    v_dt_id := null;
    v_ncc := nullif(trim(coalesce(v_line->>'ncc','')),'');

    if nullif(v_line->>'debtId','') is not null then
      select * into v_debt from debts where id = (v_line->>'debtId')::uuid;
      if v_debt is not null then
        v_dt_id := v_debt.doi_tuong_id;
        v_ncc := coalesce(v_ncc, v_debt.ten_doi_tuong);
      end if;
    end if;

    -- Hybrid rule: a free (non-linked) line must be justified before submit.
    if v_status = 'Chờ duyệt' and (v_line->>'debtId') is null and v_giaitrinh is null then
      raise exception 'Dòng "%" không nối khoản công nợ đã duyệt — cần nhập giải trình.', coalesce(v_ncc,'(chưa có NCC)');
    end if;
    if v_ncc is null then
      raise exception 'Mỗi dòng cần có tên nhà cung cấp.';
    end if;

    insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so, giai_trinh)
    values (
      v_id,
      nullif(v_line->>'debtId','')::uuid,
      v_dt_id,
      v_ncc,
      coalesce(parse_number(v_line->>'keHoach'), 0),
      v_sotien,
      v_line->>'noiDung',
      case when coalesce(v_line->>'hinhThucTT','CK') = 'Tiền mặt' then 'Tiền mặt' else 'CK' end,
      v_line->>'tinhTrangHoSo',
      v_giaitrinh
    );
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Đề xuất thanh toán cần ít nhất một dòng có số tiền hợp lệ.';
  end if;

  perform write_audit(v_actor, 'CREATE_PAYMENT_REQUEST', 'payment_requests', v_ma, null,
    jsonb_build_object('lines', v_count, 'status', v_status), 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuatTT', v_ma, 'status', v_status, 'lines', v_count);
end;
$$;

-- Shared serializer: one request with its lines + total.
create or replace function payment_request_json_(p_id uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'MaDeXuatTT', pr.ma_de_xuat_tt,
    'Ngay', to_char(pr.ngay, 'YYYY-MM-DD'),
    'TrangThai', pr.trang_thai,
    'GhiChu', pr.ghi_chu,
    'LyDoTuChoi', pr.ly_do_tu_choi,
    'NguoiLap', (select name from profiles where id = pr.nguoi_lap),
    'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr.id), 0),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ncc', l.ncc, 'keHoach', l.ke_hoach, 'soTien', l.so_tien,
        'noiDung', l.noi_dung, 'hinhThucTT', l.hinh_thuc_tt,
        'tinhTrangHoSo', l.tinh_trang_ho_so, 'giaiTrinh', l.giai_trinh,
        'maCN', (select ma_cn from debts where id = l.debt_id),
        'linked', (l.debt_id is not null)
      ) order by l.created_at)
      from payment_request_lines l where l.request_id = pr.id
    ), '[]'::jsonb)
  )
  from payment_requests pr where pr.id = p_id;
$$;

create or replace function rpc_get_pending_payment_requests()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('payment:approve');
  select coalesce(jsonb_agg(payment_request_json_(id) order by created_at desc), '[]'::jsonb) into v_rows
  from payment_requests where trang_thai = 'Chờ duyệt';
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_get_my_payment_requests(p_limit int default 30)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_rows jsonb;
begin
  v_actor := require_permission('payment:request');
  select coalesce(jsonb_agg(payment_request_json_(id) order by created_at desc), '[]'::jsonb) into v_rows
  from (select id, created_at from payment_requests where nguoi_lap = v_actor.id
        order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) s;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_approve_payment_request(p_ma text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests;
begin
  v_actor := require_permission('payment:approve');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Chờ duyệt' then raise exception 'Đề xuất % không ở trạng thái chờ duyệt.', p_ma; end if;
  update payment_requests set trang_thai = 'Đã duyệt', nguoi_duyet = v_actor.id, approved_at = now(),
    ghi_chu = case when nullif(trim(coalesce(p_note,'')),'') is not null then coalesce(ghi_chu,'')||' | Duyệt: '||trim(p_note) else ghi_chu end
  where id = v_pr.id;
  perform write_audit(v_actor, 'APPROVE_PAYMENT_REQUEST', 'payment_requests', p_ma, to_jsonb(v_pr), jsonb_build_object('note', p_note), 'OK', coalesce(nullif(trim(p_note),''),'Đã duyệt'));
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma);
end;
$$;

create or replace function rpc_reject_payment_request(p_ma text, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests;
begin
  v_actor := require_permission('payment:approve');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  update payment_requests set trang_thai = 'Từ chối', nguoi_duyet = v_actor.id, approved_at = now(), ly_do_tu_choi = p_reason
  where id = v_pr.id;
  perform write_audit(v_actor, 'REJECT_PAYMENT_REQUEST', 'payment_requests', p_ma, to_jsonb(v_pr), jsonb_build_object('reason', p_reason), 'OK', p_reason);
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma);
end;
$$;

-- Governed disbursement: only runs on an APPROVED request. Applies each line's
-- exact amount to its linked obligation (immutable allocation), or records a
-- standalone payment for free lines.
create or replace function rpc_execute_payment_request(p_ma text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_pr payment_requests; v_line payment_request_lines;
  v_ma_tt text; v_pay_id uuid; v_dt doi_tuong; v_ma_cn text; v_n int := 0;
begin
  v_actor := require_permission('payment:execute');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Đã duyệt' then
    raise exception 'Chỉ được đi tiền sau khi đề xuất % đã được lãnh đạo DUYỆT.', p_ma;
  end if;

  for v_line in select * from payment_request_lines where request_id = v_pr.id
  loop
    v_ma_cn := null;
    if v_line.debt_id is not null then
      select ma_cn into v_ma_cn from debts where id = v_line.debt_id;
    end if;
    if v_line.doi_tuong_id is not null then
      select * into v_dt from doi_tuong where id = v_line.doi_tuong_id;
    else
      v_dt := ensure_doi_tuong(null, v_line.ncc, 'NCC', null, null, null, null);
    end if;

    v_ma_tt := next_code('TT');
    insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai)
    values (v_ma_tt, current_date, v_dt.id, v_dt.ten_doi_tuong, v_line.so_tien,
            case when v_line.debt_id is not null then 'MA_CN' else 'FIFO' end,
            v_ma_cn, null, format('Chi theo ĐXTT %s | %s', p_ma, coalesce(v_line.noi_dung,'')), v_actor.id, 'Đã ghi nhận')
    returning id into v_pay_id;

    if v_line.debt_id is not null then
      insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
      values (v_pay_id, v_line.debt_id, v_ma_cn, v_line.so_tien);
      update debts set da_thanh_toan = da_thanh_toan + v_line.so_tien, ngay_tt_cuoi = current_date
      where id = v_line.debt_id;
    end if;
    v_n := v_n + 1;
  end loop;

  update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id;
  perform write_audit(v_actor, 'EXECUTE_PAYMENT_REQUEST', 'payment_requests', p_ma, to_jsonb(v_pr), jsonb_build_object('payments', v_n), 'OK', 'Đã đi tiền theo đề xuất đã duyệt.');
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma, 'payments', v_n);
end;
$$;

grant execute on function rpc_get_payable_debts(text) to authenticated;
grant execute on function rpc_create_payment_request(jsonb) to authenticated;
grant execute on function rpc_get_pending_payment_requests() to authenticated;
grant execute on function rpc_get_my_payment_requests(int) to authenticated;
grant execute on function rpc_approve_payment_request(text, text) to authenticated;
grant execute on function rpc_reject_payment_request(text, text) to authenticated;
grant execute on function rpc_execute_payment_request(text) to authenticated;
