-- ============================================================================
-- 0045_proposal_detail_any.sql
--  rpc_proposal_detail: xem CHI TIẾT đầy đủ 1 đề xuất cho MỌI vai trò đăng nhập
--  (recent:read) — dùng cho màn "Phiếu đã duyệt", lịch sử, v.v. Trả đủ trường +
--  đính kèm + mốc thời gian + người duyệt + bộ phận + dòng vật tư (chỉ đọc).
-- ============================================================================

create or replace function rpc_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('recent:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;

  select jsonb_build_object(
    'MaDeXuat', v_p.ma_de_xuat,
    'LoaiDeXuat', v_p.loai_de_xuat,
    'TrangThai', v_p.trang_thai,
    'BoPhan', v_p.bo_phan,
    'NguoiDeNghi', v_p.nguoi_de_nghi,
    'NguoiTao', (select name from profiles where id = v_p.nguoi_tao),
    'TenDoiTuong', v_p.ten_doi_tuong,
    'DieuKhoanTT', v_p.dieu_khoan_tt,
    'HanThanhToan', to_char(v_p.han_thanh_toan, 'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho,
    'TruongBpDuyet', v_p.truong_bp_duyet,
    'Prepay', v_p.prepay,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan,
    'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach,
    'NoiDung', v_p.noi_dung,
    'GhiChu', v_p.ghi_chu,
    'LyDoTraLai', v_p.ly_do_tra_lai,
    'Attachments', coalesce(v_p.attachments, '[]'::jsonb),
    'ThoiGianTao', to_char(v_p.created_at, 'YYYY-MM-DD HH24:MI'),
    'ThoiGianDuyet', to_char(v_p.approved_at, 'YYYY-MM-DD HH24:MI'),
    'NguoiDuyet', (select name from profiles where id = v_p.nguoi_duyet),
    'DaNghiemThu', exists(select 1 from debts d where d.proposal_id = v_p.id and d.sl_thuc_nhan is not null),
    'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id = v_p.id and d.da_thanh_toan > 0),
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines where proposal_id = v_p.id), 0),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
        'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu
      ) order by l.ma_line), '[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id)
  ) into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

grant execute on function rpc_proposal_detail(text) to authenticated;
