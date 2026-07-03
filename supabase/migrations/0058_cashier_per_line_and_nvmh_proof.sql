-- ============================================================================
-- 0058_cashier_per_line_and_nvmh_proof.sql
--  * Thủ quỹ xác nhận chuyển tiền THEO TỪNG KHOẢN (từng dòng của ĐXTT), mỗi
--    khoản kèm ảnh chuyển khoản riêng. Khi tất cả khoản đã chuyển -> ĐXTT 'Đã chi'.
--  * NVMH xem được ẢNH CHUYỂN KHOẢN của khoản mình đề xuất (trong "Đề xuất của tôi").
-- ============================================================================

alter table payment_request_lines add column if not exists paid boolean not null default false;
alter table payment_request_lines add column if not exists paid_at timestamptz;
alter table payment_request_lines add column if not exists proof_files jsonb not null default '[]'::jsonb;

-- ---- Thủ quỹ: xác nhận đã chuyển 1 khoản (1 dòng) --------------------------
create or replace function rpc_cashier_pay_line(p_line_id uuid, p_proof jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_line payment_request_lines; v_pr payment_requests;
  v_dt doi_tuong; v_ma_cn text; v_ma_tt text; v_pay_id uuid; v_creator uuid; v_ma_dx text;
  v_remaining int;
begin
  v_actor := require_permission('payment:execute');
  select * into v_line from payment_request_lines where id = p_line_id;
  if v_line is null then raise exception 'Không tìm thấy khoản chi.'; end if;
  if v_line.paid then raise exception 'Khoản này đã được xác nhận chuyển rồi.'; end if;
  select * into v_pr from payment_requests where id = v_line.request_id;
  if v_pr.trang_thai <> 'Đã duyệt' then
    raise exception 'Chỉ chuyển tiền sau khi đề xuất % đã được lãnh đạo DUYỆT.', v_pr.ma_de_xuat_tt;
  end if;

  v_ma_cn := null; v_creator := null; v_ma_dx := null;
  if v_line.debt_id is not null then
    select ma_cn into v_ma_cn from debts where id = v_line.debt_id;
    select p.nguoi_tao, p.ma_de_xuat into v_creator, v_ma_dx
      from debts d left join proposals p on p.id = d.proposal_id where d.id = v_line.debt_id;
  end if;
  if v_line.doi_tuong_id is not null then
    select * into v_dt from doi_tuong where id = v_line.doi_tuong_id;
  else
    v_dt := ensure_doi_tuong(null, v_line.ncc, 'NCC', null, null, null, null);
  end if;

  v_ma_tt := next_code('TT');
  insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai, proof_files)
  values (v_ma_tt, current_date, v_dt.id, v_dt.ten_doi_tuong, v_line.so_tien,
          case when v_line.debt_id is not null then 'MA_CN' else 'FIFO' end,
          v_ma_cn, null, format('Chi theo ĐXTT %s | %s', v_pr.ma_de_xuat_tt, coalesce(v_line.noi_dung,'')), v_actor.id, 'Đã ghi nhận',
          coalesce(p_proof, '[]'::jsonb))
  returning id into v_pay_id;

  if v_line.debt_id is not null then
    insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
    values (v_pay_id, v_line.debt_id, v_ma_cn, v_line.so_tien);
    update debts set da_thanh_toan = da_thanh_toan + v_line.so_tien, ngay_tt_cuoi = current_date
    where id = v_line.debt_id;
    if v_creator is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (v_creator, 'payment_done', 'Khoản của bạn đã được chuyển tiền',
              coalesce(v_ma_dx,'') || ' · ' || coalesce(v_ma_cn,'') || ' · ' || to_char(v_line.so_tien,'FM999,999,999') || 'đ đã chuyển (thủ quỹ: ' || coalesce(v_actor.name,'') || ')',
              'proposal', coalesce(v_ma_dx, v_ma_cn));
    end if;
  end if;

  update payment_request_lines set paid = true, paid_at = now(), proof_files = coalesce(p_proof,'[]'::jsonb) where id = v_line.id;

  -- Nếu tất cả khoản trong phiếu đã chuyển -> đánh dấu phiếu Đã chi.
  select count(*) into v_remaining from payment_request_lines where request_id = v_pr.id and paid = false;
  if v_remaining = 0 then
    update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id;
  end if;

  perform write_audit(v_actor, 'CASHIER_PAY_LINE', 'payment_request_lines', v_line.id::text, to_jsonb(v_line),
    jsonb_build_object('proof', jsonb_array_length(coalesce(p_proof,'[]'::jsonb)), 'remaining', v_remaining), 'OK', 'Thủ quỹ xác nhận chuyển 1 khoản.');
  return jsonb_build_object('ok', true, 'maDeXuatTT', v_pr.ma_de_xuat_tt, 'remaining', v_remaining);
end; $$;
grant execute on function rpc_cashier_pay_line(uuid, jsonb) to authenticated;

-- ---- Hàng đợi thủ quỹ: kèm id + trạng thái + ảnh từng dòng ------------------
create or replace function rpc_get_cashier_queue() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('payment:execute');
  select coalesce(jsonb_agg(x order by (x->>'ngay') asc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maDeXuatTT', pr.ma_de_xuat_tt, 'ngay', to_char(pr.ngay,'YYYY-MM-DD'),
      'nguoiLap', (select name from profiles where id = pr.nguoi_lap),
      'tong', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr.id), 0),
      'daChuyen', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr.id and paid), 0),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object(
          'lineId', l.id, 'ncc', l.ncc, 'soTien', l.so_tien, 'noiDung', l.noi_dung, 'hinhThucTT', l.hinh_thuc_tt,
          'maCN', (select ma_cn from debts where id = l.debt_id),
          'soTk', dt.so_tk_ngan_hang, 'chiNhanh', dt.chi_nhanh_ngan_hang, 'mst', dt.mst,
          'chungTu', coalesce((select nghiem_thu_files from debts where id = l.debt_id), '[]'::jsonb),
          'paid', l.paid, 'paidProof', coalesce(l.proof_files,'[]'::jsonb)
        ) order by l.created_at), '[]'::jsonb)
        from payment_request_lines l left join doi_tuong dt on dt.id = l.doi_tuong_id
        where l.request_id = pr.id)
    ) as x
    from payment_requests pr
    where pr.trang_thai = 'Đã duyệt'
      and exists (select 1 from payment_request_lines l where l.request_id = pr.id and l.paid = false)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
grant execute on function rpc_get_cashier_queue() to authenticated;

-- ---- NVMH: "Đề xuất của tôi" kèm ẢNH CHUYỂN KHOẢN của khoản đã chi ----------
create or replace function rpc_get_my_proposals(p_limit int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_rows jsonb;
begin
  if v_uid is null then raise exception 'Chưa đăng nhập.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'MaDeXuat', ma_de_xuat, 'LoaiDeXuat', loai_de_xuat,
    'Ngay', to_char(ngay_de_xuat, 'YYYY-MM-DD'), 'TenDoiTuong', ten_doi_tuong,
    'TrangThai', trang_thai, 'GhiChu', ghi_chu, 'LyDoTraLai', ly_do_tra_lai,
    'HanThanhToan', to_char(han_thanh_toan, 'YYYY-MM-DD'), 'DieuKhoanTT', dieu_khoan_tt,
    'BoPhan', bo_phan,
    'SoDong', (select count(*) from proposal_lines l where l.proposal_id = p.id),
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0),
    'AnhChuyenKhoan', (
      select coalesce(jsonb_agg(pf), '[]'::jsonb)
      from (
        select jsonb_array_elements(pm.proof_files) as pf
        from payments pm join debts d on d.ma_cn = pm.ma_cn
        where d.proposal_id = p.id and jsonb_array_length(coalesce(pm.proof_files,'[]'::jsonb)) > 0
      ) s
    )
  ) order by created_at desc), '[]'::jsonb) into v_rows
  from (select * from proposals where nguoi_tao = v_uid order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) p;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
grant execute on function rpc_get_my_proposals(int) to authenticated;
