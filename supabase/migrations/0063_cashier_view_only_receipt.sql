-- ============================================================================
-- 0063_cashier_view_only_receipt.sql
--  Thủ quỹ CHỈ ĐƯỢC XEM màn "Duyệt hồ sơ thanh toán" (không duyệt/không trả lại).
--  Quyền duyệt (congno:confirm) chỉ thuộc KTTH.
--   * Gỡ congno:confirm khỏi ThuQuy (giữ receipt:review để xem danh sách).
--   * rpc_get_receipt_review chỉ cần 'receipt:review' (cả KTTH & Thủ quỹ có).
--   * rpc_confirm_cong_no / rpc_return_receipt VẪN cần 'congno:confirm' (chỉ KTTH).
-- ============================================================================

delete from role_permissions where role = 'ThuQuy' and permission = 'congno:confirm';

create or replace function rpc_get_receipt_review(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('receipt:review');
  select coalesce(jsonb_agg(x order by (x->>'ngayNhan') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maCN', d.ma_cn, 'maDeXuat', p.ma_de_xuat, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', d.ten_doi_tuong,
      'boPhan', p.bo_phan, 'nguoiDeNghi', p.nguoi_de_nghi,
      'matHang', d.mat_hang, 'dvt', (select dvt from materials m where m.id = d.material_id),
      'slDat', d.sl_dat, 'slThucNhan', d.sl_thuc_nhan, 'donGia', d.don_gia, 'vatRate', d.vat_rate,
      'thanhTienThucNhan', round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
      'daThanhToan', d.da_thanh_toan, 'hanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD'),
      'ngayNhan', to_char(d.ngay_nhan,'YYYY-MM-DD'), 'dieuKhoanTT', d.dieu_khoan_tt,
      'chungTuTypes', coalesce(d.chung_tu_types,'[]'::jsonb),
      'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb), 'baoGia', coalesce(p.attachments,'[]'::jsonb)
    ) as x
    from debts d
    left join proposals p on p.id = d.proposal_id
    left join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false and d.sl_thuc_nhan is not null
      and d.cong_no_confirmed = false and not d.prepay and d.cho_bo_sung = false
    order by d.ngay_nhan desc nulls last
    limit least(greatest(coalesce(p_limit,200),1),500)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
grant execute on function rpc_get_receipt_review(int) to authenticated;
