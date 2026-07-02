-- ============================================================================
-- 0046_richer_lists.sql
--  Bổ sung trường để "Cập nhật thanh toán" và "Đề xuất của tôi" hiện đủ thông
--  tin ngay trên thẻ (không cần mở chi tiết): mặt hàng, SL đặt, ĐVT, NCC,
--  đơn giá chưa VAT, %VAT, giá sau VAT, hạn TT, điều khoản TT.
--  (rpc_get_open_receipt_items đã đủ trường từ trước — chỉ FE hiển thị thêm.)
-- ============================================================================

-- Danh sách khoản còn phải trả — kèm đủ trường của dòng công nợ.
create or replace function rpc_list_open_debts(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),''); v_rows jsonb;
begin
  perform require_permission('payment:create');
  select coalesce(jsonb_agg(x order by (x->>'hanThanhToan') nulls last), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maCN', vd.ma_cn, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', vd.ten_doi_tuong, 'matHang', vd.mat_hang,
      'dvt', (select dvt from materials m where m.id = vd.material_id),
      'slDat', vd.sl_dat, 'slThucNhan', vd.sl_thuc_nhan, 'donGia', vd.don_gia, 'vatRate', vd.vat_rate,
      'thanhTienDat', vd.thanh_tien_dat, 'dieuKhoanTT', vd.dieu_khoan_tt,
      'maDeXuat', (select ma_de_xuat from proposals p where p.id = vd.proposal_id),
      'nguoiDeNghi', (select nguoi_de_nghi from proposals p where p.id = vd.proposal_id),
      'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', vd.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
      'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'trangThai', vd.trang_thai_dong
    ) as x
    from v_debts vd join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false and vd.so_tien_con_lai > 0 and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- "Đề xuất của tôi" — kèm hạn TT, điều khoản, số dòng để hiện gọn trên thẻ.
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
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0)
  ) order by created_at desc), '[]'::jsonb) into v_rows
  from (select * from proposals where nguoi_tao = v_uid order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) p;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

grant execute on function rpc_list_open_debts(text) to authenticated;
grant execute on function rpc_get_my_proposals(int) to authenticated;
