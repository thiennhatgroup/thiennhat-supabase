-- ============================================================================
-- 0040_get_proposal_reason.sql
--  rpc_get_proposal trả thêm LyDoTraLai (để form sửa nháp hiển thị yêu cầu của
--  kế toán/trưởng bộ phận) và Prepay (giữ đúng cờ trả-trước khi sửa lại).
-- ============================================================================

create or replace function rpc_get_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  select jsonb_build_object('MaDeXuat', v_p.ma_de_xuat, 'TrangThai', v_p.trang_thai, 'LoaiDeXuat', v_p.loai_de_xuat,
    'NgayDeXuat', to_char(v_p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', v_p.nguoi_de_nghi, 'BoPhan', v_p.bo_phan,
    'TenDoiTuong', v_p.ten_doi_tuong, 'DieuKhoanTT', v_p.dieu_khoan_tt, 'HanThanhToan', to_char(v_p.han_thanh_toan,'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho, 'TruongBpDuyet', v_p.truong_bp_duyet, 'Prepay', v_p.prepay, 'LyDoTraLai', v_p.ly_do_tra_lai,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach, 'Attachments', v_p.attachments,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('matHang', l.mat_hang, 'slDat', l.sl_dat, 'donGia', l.don_gia_chua_vat, 'vat', (l.vat_rate*100)||'%', 'ghiChu', l.ghi_chu) order by l.ma_line),'[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id))
  into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

grant execute on function rpc_get_proposal(text) to authenticated;
