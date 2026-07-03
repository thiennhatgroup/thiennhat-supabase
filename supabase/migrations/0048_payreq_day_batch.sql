-- ============================================================================
-- 0048_payreq_day_batch.sql  (Đợt F)
--  * Chủ tịch duyệt các đề xuất thanh toán GỘP THEO NGÀY: một khối/ngày, bóc
--    tách theo bộ phận + tình trạng hồ sơ + tổng tiền ngày. Duyệt cả ngày một thể.
--  * Trả lại một phiếu thanh toán cho kế toán (về Nháp) để sửa & gửi lại
--    (giống luồng trả lại đề xuất mua hàng). Kế toán sửa trên chính phiếu đó.
-- ============================================================================

alter table payment_requests add column if not exists ly_do_tra_lai text;

-- ---- Danh sách chờ duyệt, GỘP THEO NGÀY ------------------------------------
create or replace function rpc_get_pending_payreq_grouped() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('payment:approve');
  select coalesce(jsonb_agg(day_json order by day_json->>'ngay' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'ngay', to_char(pr.ngay,'YYYY-MM-DD'),
      'soPhieu', count(distinct pr.id),
      'tong', coalesce(sum(l.so_tien), 0),
      'boPhan', (
        select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'tong', t) order by t desc), '[]'::jsonb)
        from (
          select coalesce(pp.bo_phan, '(Tự nhập / không rõ)') as bp, sum(ll.so_tien) as t
          from payment_requests pr2
          join payment_request_lines ll on ll.request_id = pr2.id
          left join debts dd on dd.id = ll.debt_id
          left join proposals pp on pp.id = dd.proposal_id
          where pr2.trang_thai = 'Chờ duyệt' and pr2.ngay = pr.ngay
          group by 1
        ) s
      ),
      'phieu', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'maDeXuatTT', pr3.ma_de_xuat_tt,
          'nguoiLap', (select name from profiles where id = pr3.nguoi_lap),
          'tong', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr3.id), 0),
          'lines', (select coalesce(jsonb_agg(jsonb_build_object(
              'ncc', l3.ncc, 'soTien', l3.so_tien, 'noiDung', l3.noi_dung,
              'hinhThucTT', l3.hinh_thuc_tt, 'tinhTrangHoSo', l3.tinh_trang_ho_so, 'giaiTrinh', l3.giai_trinh,
              'maCN', (select ma_cn from debts where id = l3.debt_id),
              'matHang', (select mat_hang from debts where id = l3.debt_id),
              'boPhan', (select pp.bo_phan from debts dd join proposals pp on pp.id = dd.proposal_id where dd.id = l3.debt_id)
            ) order by l3.created_at), '[]'::jsonb) from payment_request_lines l3 where l3.request_id = pr3.id)
        ) order by pr3.created_at), '[]'::jsonb)
        from payment_requests pr3 where pr3.trang_thai = 'Chờ duyệt' and pr3.ngay = pr.ngay
      )
    ) as day_json
    from payment_requests pr
    join payment_request_lines l on l.request_id = pr.id
    where pr.trang_thai = 'Chờ duyệt'
    group by pr.ngay
  ) t;
  return jsonb_build_object('ok', true, 'days', v_rows);
end; $$;

-- ---- Duyệt CẢ NGÀY (tất cả phiếu chờ duyệt của ngày đó) ---------------------
create or replace function rpc_approve_payreq_day(p_ngay date, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_n int := 0; r record;
begin
  v_actor := require_permission('payment:approve');
  for r in select ma_de_xuat_tt from payment_requests where trang_thai = 'Chờ duyệt' and ngay = p_ngay loop
    perform rpc_approve_payment_request(r.ma_de_xuat_tt, coalesce(nullif(trim(p_note),''), 'Duyệt cả ngày'));
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Không có phiếu nào chờ duyệt trong ngày %.', p_ngay; end if;
  return jsonb_build_object('ok', true, 'approved', v_n);
end; $$;

-- ---- Trả lại một phiếu về Nháp cho kế toán sửa & gửi lại --------------------
create or replace function rpc_bounce_payment_request(p_ma text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests; v_reason text := nullif(trim(coalesce(p_reason,'')),'');
begin
  v_actor := require_permission('payment:approve');
  if v_reason is null then raise exception 'Cần nhập lý do trả lại để kế toán chỉnh.'; end if;
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Chờ duyệt' then raise exception 'Chỉ trả lại phiếu đang chờ duyệt.'; end if;
  update payment_requests set trang_thai = 'Nháp', ly_do_tra_lai = v_reason where id = v_pr.id;
  if v_pr.nguoi_lap is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (v_pr.nguoi_lap, 'payreq_bounced', 'Đề xuất thanh toán bị trả lại',
            p_ma || ' bị ' || coalesce(v_actor.name,'') || ' trả lại: ' || v_reason, 'payreq', p_ma);
  end if;
  perform write_audit(v_actor, 'BOUNCE_PAYREQ', 'payment_requests', p_ma, to_jsonb(v_pr), jsonb_build_object('reason', v_reason), 'OK', v_reason);
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma);
end; $$;

-- ---- Lấy 1 phiếu để kế toán sửa ---------------------------------------------
create or replace function rpc_get_payment_request(p_ma text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests; v_j jsonb;
begin
  v_actor := require_permission('payment:request');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  select jsonb_build_object('MaDeXuatTT', v_pr.ma_de_xuat_tt, 'Ngay', to_char(v_pr.ngay,'YYYY-MM-DD'),
    'TrangThai', v_pr.trang_thai, 'GhiChu', v_pr.ghi_chu, 'LyDoTraLai', v_pr.ly_do_tra_lai,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'debtId', l.debt_id, 'ncc', l.ncc, 'maCN', (select ma_cn from debts where id = l.debt_id),
        'keHoach', l.ke_hoach, 'soTien', l.so_tien, 'noiDung', l.noi_dung,
        'hinhThucTT', l.hinh_thuc_tt, 'tinhTrangHoSo', l.tinh_trang_ho_so, 'giaiTrinh', l.giai_trinh
      ) order by l.created_at), '[]'::jsonb) from payment_request_lines l where l.request_id = v_pr.id))
  into v_j;
  return jsonb_build_object('ok', true, 'pr', v_j);
end; $$;

-- ---- Kế toán sửa phiếu Nháp (thay toàn bộ dòng) + gửi lại -------------------
create or replace function rpc_update_payment_request(p_ma text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests;
  v_status text := case when coalesce(p_payload->>'status','Nháp') = 'Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_line jsonb; v_sotien numeric; v_ncc text; v_giaitrinh text; v_dt_id uuid; v_debt debts; v_count int := 0;
begin
  v_actor := require_permission('payment:request');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Nháp' then raise exception 'Chỉ sửa được phiếu đang Nháp.'; end if;
  update payment_requests set
    ngay = coalesce((p_payload->>'ngay')::date, ngay), ghi_chu = p_payload->>'ghiChu',
    trang_thai = v_status, ly_do_tra_lai = case when v_status = 'Chờ duyệt' then null else ly_do_tra_lai end
  where id = v_pr.id;
  delete from payment_request_lines where request_id = v_pr.id;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_sotien := parse_number(v_line->>'soTien');
    if v_sotien is null or v_sotien <= 0 then continue; end if;
    v_giaitrinh := nullif(trim(coalesce(v_line->>'giaiTrinh','')),'');
    v_ncc := nullif(trim(coalesce(v_line->>'ncc','')),''); v_dt_id := null;
    if nullif(v_line->>'debtId','') is not null then
      select * into v_debt from debts where id = (v_line->>'debtId')::uuid;
      if v_debt is not null then v_dt_id := v_debt.doi_tuong_id; v_ncc := coalesce(v_ncc, v_debt.ten_doi_tuong); end if;
    end if;
    if v_status = 'Chờ duyệt' and (v_line->>'debtId') is null and v_giaitrinh is null then
      raise exception 'Dòng "%" ngoài công nợ — cần giải trình.', coalesce(v_ncc,'(chưa có NCC)'); end if;
    if v_ncc is null then raise exception 'Mỗi dòng cần có tên nhà cung cấp.'; end if;
    insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so, giai_trinh)
    values (v_pr.id, nullif(v_line->>'debtId','')::uuid, v_dt_id, v_ncc, coalesce(parse_number(v_line->>'keHoach'),0), v_sotien, v_line->>'noiDung',
      case when coalesce(v_line->>'hinhThucTT','CK') = 'Tiền mặt' then 'Tiền mặt' else 'CK' end, v_line->>'tinhTrangHoSo', v_giaitrinh);
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'Đề xuất thanh toán cần ít nhất một dòng có số tiền.'; end if;
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma, 'status', v_status);
end; $$;

grant execute on function rpc_get_pending_payreq_grouped() to authenticated;
grant execute on function rpc_approve_payreq_day(date, text) to authenticated;
grant execute on function rpc_bounce_payment_request(text, text) to authenticated;
grant execute on function rpc_get_payment_request(text) to authenticated;
grant execute on function rpc_update_payment_request(text, jsonb) to authenticated;
