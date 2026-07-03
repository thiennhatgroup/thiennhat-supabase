-- ============================================================================
-- 0060_hardening.sql — Rà soát senior backend: an toàn dữ liệu, hiệu năng, chi phí.
--  (1) Index cho các cột join/filter nóng.
--  (2) Thủ quỹ: khoá dòng (chống race) + chặn chuyển VƯỢT số dư (công nợ âm)
--      + báo KTTH và NVMH khi đã chuyển.
--  (3) Chặn ghi công nợ THỦ CÔNG cho khoản đã được thủ quỹ chi (tránh trừ trùng).
--  (4) rpc_list_payments trả kèm ẢNH chuyển khoản (KTTH xem lại).
--  (5) LIMIT cho chi tiết dashboard.
--  (6) prune_old_data(): dọn dữ liệu cũ (CHẠY TAY sau khi đã backup).
--  (7) Đưa webhook push vào migration (tái lập được khi deploy mới).
-- ============================================================================

-- ---- (1) INDEX --------------------------------------------------------------
create index if not exists idx_debts_proposal        on debts (proposal_id);
create index if not exists idx_proposals_nguoi_tao    on proposals (nguoi_tao);
create index if not exists idx_proposals_created      on proposals (created_at);
create index if not exists idx_proposals_bo_phan      on proposals (bo_phan);
create index if not exists idx_payments_ngay          on payments (ngay_thanh_toan);
create index if not exists idx_payments_ma_cn         on payments (ma_cn);
create index if not exists idx_payreq_lines_paid      on payment_request_lines (request_id, paid);

-- ---- (2) Thủ quỹ chi 1 khoản: an toàn ---------------------------------------
create or replace function rpc_cashier_pay_line(p_line_id uuid, p_proof jsonb default '[]'::jsonb, p_amount numeric default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_line payment_request_lines; v_pr payment_requests;
  v_dt doi_tuong; v_ma_cn text; v_ma_tt text; v_pay_id uuid; v_creator uuid; v_ma_dx text;
  v_remaining int; v_amt numeric; v_du numeric;
begin
  v_actor := require_permission('payment:execute');
  -- Khoá dòng để tránh 2 request chi trùng (race).
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
    -- Chặn chuyển vượt số dư còn lại (tránh công nợ âm). Cho phép lệch ≤ 1đ do làm tròn.
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
          v_ma_cn, null, format('Chi theo ĐXTT %s | %s', v_pr.ma_de_xuat_tt, coalesce(v_line.noi_dung,'')), v_actor.id, 'Đã ghi nhận',
          coalesce(p_proof, '[]'::jsonb))
  returning id into v_pay_id;

  if v_line.debt_id is not null then
    insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
    values (v_pay_id, v_line.debt_id, v_ma_cn, v_amt);
    update debts set da_thanh_toan = da_thanh_toan + v_amt, ngay_tt_cuoi = current_date where id = v_line.debt_id;
    if v_creator is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (v_creator, 'payment_done', 'Khoản của bạn đã được chuyển tiền',
              coalesce(v_ma_dx,'') || ' · ' || coalesce(v_ma_cn,'') || ' · ' || to_char(v_amt,'FM999,999,999') || 'đ đã chuyển (thủ quỹ: ' || coalesce(v_actor.name,'') || ')',
              'proposal', coalesce(v_ma_dx, v_ma_cn));
    end if;
  end if;

  -- Báo KẾ TOÁN (KTTH) mỗi khoản đã chuyển (kèm mã ĐXTT để xem lại + ảnh ở màn Cập nhật thanh toán).
  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'payment_done', 'Thủ quỹ đã chuyển 1 khoản',
         v_pr.ma_de_xuat_tt || ' · ' || coalesce(v_ma_cn, v_line.ncc, '') || ' · ' || to_char(v_amt,'FM999,999,999') || 'đ',
         'debtpay', v_pr.ma_de_xuat_tt
  from profiles where role in ('KeToanCongNo','Admin') and status = 'Hoạt động';

  update payment_request_lines set paid = true, paid_at = now(), proof_files = coalesce(p_proof,'[]'::jsonb), so_tien_da_chuyen = v_amt where id = v_line.id;

  select count(*) into v_remaining from payment_request_lines where request_id = v_pr.id and paid = false;
  if v_remaining = 0 then update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id; end if;

  perform write_audit(v_actor, 'CASHIER_PAY_LINE', 'payment_request_lines', v_line.id::text, to_jsonb(v_line),
    jsonb_build_object('amount', v_amt, 'remaining', v_remaining), 'OK', 'Thủ quỹ xác nhận chuyển 1 khoản.');
  return jsonb_build_object('ok', true, 'maDeXuatTT', v_pr.ma_de_xuat_tt, 'remaining', v_remaining);
end; $$;
grant execute on function rpc_cashier_pay_line(uuid, jsonb, numeric) to authenticated;

-- ---- (3) Chặn ghi công nợ thủ công cho khoản đã được thủ quỹ chi ------------
create or replace function rpc_record_debt_payment(p_ma_cn text, p_so_tien numeric, p_ngay date default null, p_chung_tu text default null, p_ghi_chu text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_debt debts; v_pay uuid; v_ngay date; v_ma_tt text;
begin
  v_actor := require_permission('payment:create');
  if p_so_tien is null or p_so_tien <= 0 then raise exception 'Số tiền đã trả phải lớn hơn 0.'; end if;
  select * into v_debt from debts where ma_cn = trim(coalesce(p_ma_cn,'')) and is_archived = false;
  if v_debt is null then raise exception 'Không tìm thấy khoản công nợ %.', p_ma_cn; end if;
  -- Nếu khoản đã được thủ quỹ chi (có dòng ĐXTT paid) -> chặn để tránh trừ trùng.
  if exists (select 1 from payment_request_lines l where l.debt_id = v_debt.id and l.paid) then
    raise exception 'Khoản % đã được thủ quỹ chi — không ghi thủ công (tránh trừ công nợ hai lần). Nếu cần điều chỉnh, hủy khoản chi ở lịch sử rồi ghi lại.', v_debt.ma_cn;
  end if;
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
grant execute on function rpc_record_debt_payment(text, numeric, date, text, text) to authenticated;

-- ---- (4) Lịch sử thanh toán kèm ẢNH chuyển khoản (KTTH xem lại) -------------
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
      'anhChuyenKhoan', coalesce(p.proof_files,'[]'::jsonb),
      'createdAt', to_char(p.created_at,'YYYY-MM-DD HH24:MI:SS')
    ) as x
    from payments p left join doi_tuong dt on dt.id = p.doi_tuong_id
    where (v_ma is null or dt.ma_doi_tuong = v_ma)
    order by p.created_at desc limit least(greatest(coalesce(p_limit,50),1),200)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
grant execute on function rpc_list_payments(text, int) to authenticated;

-- ---- (5) LIMIT chi tiết khoản đã chi trong dashboard -----------------------
create or replace function rpc_leader_dashboard(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := coalesce(p_from, current_date - 30);
  v_to date := coalesce(p_to, current_date);
  v_dxmh jsonb; v_dxmh_bp jsonb; v_dxtt jsonb; v_chi jsonb; v_chi_bp jsonb; v_chi_detail jsonb; v_topncc jsonb;
begin
  perform require_permission('dashboard:read');
  select jsonb_build_object('count', count(*),
    'total', coalesce(sum((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id)), 0)) into v_dxmh
  from proposals p where p.created_at::date = current_date and p.trang_thai <> 'Nháp';
  select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'total', t) order by t desc), '[]'::jsonb) into v_dxmh_bp
  from (select coalesce(p.bo_phan,'(không rõ)') as bp,
          coalesce(sum((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id)),0) as t
        from proposals p where p.created_at::date = current_date and p.trang_thai <> 'Nháp' group by 1) s;
  select jsonb_build_object('count', count(distinct pr.id), 'total', coalesce(sum(l.so_tien), 0)) into v_dxtt
  from payment_requests pr join payment_request_lines l on l.request_id = pr.id
  where pr.ngay = current_date and pr.trang_thai <> 'Nháp';
  select jsonb_build_object('total', coalesce(sum(pm.so_tien),0), 'count', count(*)) into v_chi
  from payments pm where pm.ngay_thanh_toan between v_from and v_to;
  select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'total', t) order by t desc), '[]'::jsonb) into v_chi_bp
  from (select coalesce(pr.bo_phan, '(ngoài phần mềm)') as bp, sum(pm.so_tien) as t
        from payments pm left join debts d on d.ma_cn = pm.ma_cn left join proposals pr on pr.id = d.proposal_id
        where pm.ngay_thanh_toan between v_from and v_to group by 1) s;
  select coalesce(jsonb_agg(jsonb_build_object(
    'maThanhToan', pm.ma_thanh_toan, 'ngay', to_char(pm.ngay_thanh_toan,'YYYY-MM-DD'),
    'ncc', pm.ten_doi_tuong, 'soTien', pm.so_tien, 'maCN', pm.ma_cn,
    'boPhan', coalesce(pr.bo_phan,'(ngoài phần mềm)'), 'ghiChu', pm.ghi_chu,
    'proof', coalesce(pm.proof_files,'[]'::jsonb)) order by pm.ngay_thanh_toan desc, pm.created_at desc), '[]'::jsonb) into v_chi_detail
  from (
    select * from payments pm2 where pm2.ngay_thanh_toan between v_from and v_to
    order by pm2.ngay_thanh_toan desc, pm2.created_at desc limit 500
  ) pm
  left join debts d on d.ma_cn = pm.ma_cn left join proposals pr on pr.id = d.proposal_id;
  select coalesce(jsonb_agg(jsonb_build_object('ncc', ncc, 'boPhan', bp, 'total', t) order by t desc), '[]'::jsonb) into v_topncc
  from (select coalesce(pm.ten_doi_tuong,'(không rõ)') as ncc, coalesce(pr.bo_phan,'(ngoài phần mềm)') as bp, sum(pm.so_tien) as t
        from payments pm left join debts d on d.ma_cn = pm.ma_cn left join proposals pr on pr.id = d.proposal_id
        where pm.ngay_thanh_toan between v_from and v_to group by 1, 2 order by t desc limit 15) s;
  return jsonb_build_object('ok', true,
    'from', to_char(v_from,'YYYY-MM-DD'), 'to', to_char(v_to,'YYYY-MM-DD'),
    'dxmhToday', v_dxmh, 'dxmhByBoPhan', v_dxmh_bp, 'dxttToday', v_dxtt,
    'chi', v_chi, 'chiByBoPhan', v_chi_bp, 'chiDetail', v_chi_detail, 'topNcc', v_topncc);
end; $$;
grant execute on function rpc_leader_dashboard(date, date) to authenticated;

-- ---- (6) Dọn dữ liệu cũ — CHẠY TAY sau khi đã backup -----------------------
-- Ví dụ: select prune_old_data(180);  -- giữ lại 180 ngày.
create or replace function prune_old_data(p_keep_days int default 180) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_cut timestamptz := now() - (greatest(coalesce(p_keep_days,180),30) || ' days')::interval;
  v_n_notif int; v_n_audit int; v_n_net int := 0;
begin
  v_actor := require_permission('user:manage');   -- chỉ Admin
  delete from notifications where created_at < v_cut and da_doc = true; get diagnostics v_n_notif = row_count;
  delete from audit_log where created_at < v_cut; get diagnostics v_n_audit = row_count;
  -- Dọn log HTTP của pg_net (nếu có) — giữ 30 ngày.
  begin
    delete from net._http_response where created < now() - interval '30 days'; get diagnostics v_n_net = row_count;
  exception when others then v_n_net := -1; end;
  perform write_audit(v_actor, 'PRUNE_OLD_DATA', 'system', null, null,
    jsonb_build_object('notif', v_n_notif, 'audit', v_n_audit, 'net', v_n_net, 'keepDays', p_keep_days), 'OK', '');
  return jsonb_build_object('ok', true, 'notifDeleted', v_n_notif, 'auditDeleted', v_n_audit, 'netDeleted', v_n_net);
end; $$;
grant execute on function prune_old_data(int) to authenticated;

-- ---- (7) Webhook push đưa vào migration (tái lập khi deploy mới) ------------
create extension if not exists pg_net;
create or replace function tg_push_on_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform net.http_post(
    url := 'https://nsxvasvceslhhvgjkedh.supabase.co/functions/v1/send-push',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('record', to_jsonb(NEW))
  );
  return NEW;
end $$;
drop trigger if exists push_on_notify on notifications;
create trigger push_on_notify after insert on notifications
  for each row execute function tg_push_on_notify();
