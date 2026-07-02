-- ============================================================================
-- 0033_history_rpcs.sql — Dữ liệu QUÁ KHỨ cho các màn ra quyết định
--   rpc_get_approved_proposals  (+ DaNghiemThu)
--   rpc_get_payment_request_history  (đề xuất TT đã xử lý gần đây)
--   rpc_get_receipt_history          (khoản đã nghiệm thu gần đây)
-- ============================================================================

create or replace function rpc_get_approved_proposals(p_date date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_date date := coalesce(p_date, current_date); v_rows jsonb;
begin
  perform require_permission('proposal:approve');
  select coalesce(jsonb_agg(row_data order by approved_at desc), '[]'::jsonb) into v_rows
  from (
    select p.approved_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'LoaiDeXuat', p.loai_de_xuat, 'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD HH24:MI'), 'TenDoiTuong', p.ten_doi_tuong, 'NoiDung', p.noi_dung,
        'NguoiDeNghi', p.nguoi_de_nghi, 'BoPhan', p.bo_phan, 'TruongBpDuyet', p.truong_bp_duyet,
        'NguoiDuyet', (select name from profiles where id = p.nguoi_duyet), 'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'), 'Attachments', p.attachments,
        'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0),
        'DaNghiemThu', exists (select 1 from debts d where d.proposal_id = p.id and d.sl_thuc_nhan is not null),
        'DaPhatSinhTT', exists (select 1 from debts d where d.proposal_id = p.id and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))),
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
            'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id)
      ) as row_data
    from proposals p
    where p.trang_thai = 'Đã duyệt' and p.approved_at is not null and (p.approved_at at time zone 'Asia/Ho_Chi_Minh')::date = v_date
    order by p.approved_at desc
  ) x;
  return jsonb_build_object('ok', true, 'date', to_char(v_date, 'YYYY-MM-DD'), 'rows', v_rows);
end; $$;

-- Đề xuất thanh toán đã xử lý (Đã duyệt / Từ chối / Đã chi) gần đây
create or replace function rpc_get_payment_request_history(p_limit int default 40) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('payment:approve');
  select coalesce(jsonb_agg(jsonb_build_object(
      'MaDeXuatTT', pr.ma_de_xuat_tt, 'Ngay', to_char(pr.ngay,'YYYY-MM-DD'), 'TrangThai', pr.trang_thai,
      'NguoiLap', (select name from profiles where id = pr.nguoi_lap),
      'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr.id), 0),
      'LyDoTuChoi', pr.ly_do_tu_choi
    ) order by pr.updated_at desc), '[]'::jsonb) into v_rows
  from (select * from payment_requests where trang_thai in ('Đã duyệt','Từ chối','Đã chi') order by updated_at desc limit least(greatest(coalesce(p_limit,40),1),200)) pr;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- Khoản đã nghiệm thu gần đây (cho màn Nghiệm thu xem lịch sử)
create or replace function rpc_get_receipt_history(p_limit int default 40) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('receipt:update');
  select coalesce(jsonb_agg(jsonb_build_object(
      'MaCN', d.ma_cn, 'TenDoiTuong', d.ten_doi_tuong, 'MatHang', d.mat_hang,
      'SLThucNhan', d.sl_thuc_nhan, 'NgayNhan', to_char(d.ngay_nhan,'YYYY-MM-DD'),
      'HoSoDayDu', d.ho_so_day_du, 'HanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD')
    ) order by d.nghiem_thu_at desc nulls last), '[]'::jsonb) into v_rows
  from (select * from debts where sl_thuc_nhan is not null order by nghiem_thu_at desc nulls last limit least(greatest(coalesce(p_limit,40),1),200)) d;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

grant execute on function rpc_get_approved_proposals(date) to authenticated;
grant execute on function rpc_get_payment_request_history(int) to authenticated;
grant execute on function rpc_get_receipt_history(int) to authenticated;
