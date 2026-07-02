-- ============================================================================
-- 0043_payreq_detail.sql
--  rpc_payment_request_detail: khi lãnh đạo mở 1 đề xuất thanh toán, kéo ĐỦ dữ
--  liệu để có cơ sở duyệt — mỗi dòng gắn với công nợ nào thì hiện: mặt hàng,
--  ĐVT, SL đặt / thực nhận, đơn giá, %VAT, thành tiền thực nhận, đã trả, còn
--  phải trả, hạn TT, điều khoản, biên bản nghiệm thu, báo giá gốc, phiếu ĐX gốc.
-- ============================================================================

create or replace function rpc_payment_request_detail(p_ma text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests; v_j jsonb;
begin
  v_actor := require_permission('payment:approve');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;

  select jsonb_build_object(
    'MaDeXuatTT', v_pr.ma_de_xuat_tt,
    'Ngay', to_char(v_pr.ngay, 'YYYY-MM-DD'),
    'TrangThai', v_pr.trang_thai,
    'GhiChu', v_pr.ghi_chu,
    'NguoiLap', (select name from profiles where id = v_pr.nguoi_lap),
    'ThoiGianLap', to_char(v_pr.created_at, 'YYYY-MM-DD HH24:MI'),
    'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id = v_pr.id), 0),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ncc', l.ncc, 'keHoach', l.ke_hoach, 'soTien', l.so_tien, 'noiDung', l.noi_dung,
        'hinhThucTT', l.hinh_thuc_tt, 'tinhTrangHoSo', l.tinh_trang_ho_so, 'giaiTrinh', l.giai_trinh,
        'linked', (l.debt_id is not null),
        'maCN', d.ma_cn, 'matHang', d.mat_hang, 'dvt', m.dvt,
        'slDat', d.sl_dat, 'slThucNhan', d.sl_thuc_nhan, 'donGia', d.don_gia, 'vatRate', d.vat_rate,
        'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', d.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
        'hanThanhToan', to_char(d.han_thanh_toan, 'YYYY-MM-DD'), 'ngayNhan', to_char(d.ngay_nhan, 'YYYY-MM-DD'),
        'dieuKhoanTT', d.dieu_khoan_tt, 'hoSoDayDu', d.ho_so_day_du,
        'nghiemThuFiles', coalesce(d.nghiem_thu_files, '[]'::jsonb),
        'maDeXuat', p.ma_de_xuat, 'nguoiDeNghi', p.nguoi_de_nghi, 'boPhan', p.bo_phan,
        'baoGia', coalesce(p.attachments, '[]'::jsonb)
      ) order by l.created_at)
      from payment_request_lines l
      left join debts d on d.id = l.debt_id
      left join v_debts vd on vd.id = d.id
      left join materials m on m.id = d.material_id
      left join proposals p on p.id = d.proposal_id
      where l.request_id = v_pr.id
    ), '[]'::jsonb)
  ) into v_j;
  return jsonb_build_object('ok', true, 'pr', v_j);
end; $$;

grant execute on function rpc_payment_request_detail(text) to authenticated;
