-- ============================================================================
-- 0026_print_permission.sql
-- Chức năng in Đề xuất mua hàng / Phiếu YCTT chỉ dành cho bộ phận MUA HÀNG.
-- Chủ tịch, Tổng giám đốc, Kế toán không thấy 2 menu này.
-- ============================================================================

insert into role_permissions (role, permission) values
  ('NhanVienMuaHang', 'print:purchasing')
on conflict (role, permission) do nothing;

-- Dữ liệu nguồn cho 2 màn in giờ yêu cầu quyền print:purchasing (Admin bỏ qua).
create or replace function rpc_get_printable_proposals(p_only_accepted boolean default true) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('print:purchasing');
  select coalesce(jsonb_agg(row_data order by (row_data->>'NgayDuyet') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'MaDeXuat', p.ma_de_xuat,
      'LoaiDeXuat', p.loai_de_xuat,
      'NgayDeXuat', to_char(p.ngay_de_xuat, 'DD/MM/YYYY'),
      'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD'),
      'NoiDung', p.noi_dung,
      'GiaiTrinh', p.giai_trinh_ngoai_ke_hoach,
      'NguoiDeNghi', p.nguoi_de_nghi,
      'DieuKhoanTT', p.dieu_khoan_tt,
      'TenDoiTuong', p.ten_doi_tuong,
      'SoTk', dt.so_tk_ngan_hang,
      'ChiNhanh', dt.chi_nhanh_ngan_hang,
      'MST', dt.mst,
      'DaNghiemThu', exists (select 1 from debts d where d.proposal_id = p.id and d.sl_thuc_nhan is not null),
      'lines', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'MatHang', l.mat_hang,
          'SLDat', l.sl_dat,
          'DonGia', l.don_gia_chua_vat,
          'VATRate', l.vat_rate,
          'ThanhTienSauVAT', l.thanh_tien_sau_vat,
          'SLThucNhan', (select d.sl_thuc_nhan from debts d where d.proposal_id = p.id and d.mat_hang = l.mat_hang order by d.created_at limit 1),
          'GhiChu', l.ghi_chu
        ) order by l.ma_line), '[]'::jsonb)
        from proposal_lines l where l.proposal_id = p.id
      )
    ) as row_data
    from proposals p
    left join doi_tuong dt on dt.id = p.doi_tuong_id
    where p.trang_thai = 'Đã duyệt'
      and (not p_only_accepted or exists (select 1 from debts d where d.proposal_id = p.id and d.sl_thuc_nhan is not null))
    order by p.approved_at desc
    limit 300
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

grant execute on function rpc_get_printable_proposals(boolean) to authenticated;
