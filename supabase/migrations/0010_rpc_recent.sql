-- ============================================================================
-- 0010_rpc_recent.sql
-- rpc_get_recent()  mirrors apiGetRecent() — the "Dữ liệu Google Sheets gần
-- đây" panel that sits next to every form in the original webapp.
-- kind: 'proposal' | 'payment' | 'receipt' | 'debt' | 'approved'
-- ============================================================================

create or replace function rpc_get_recent(p_kind text default 'proposal', p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_limit int := least(greatest(coalesce((p_filter->>'limit')::int, 20), 1), 100);
  v_ma text := nullif(trim(coalesce(p_filter->>'maDoiTuong', '')), '');
  v_status text := nullif(trim(coalesce(p_filter->>'status', '')), '');
  v_from date := (p_filter->>'fromDate')::date;
  v_to date := (p_filter->>'toDate')::date;
  v_rows jsonb;
  v_columns jsonb;
begin
  perform require_permission('recent:read');

  if p_kind = 'payment' then
    v_columns := to_jsonb(array['MaThanhToan','NgayThanhToan','MaDoiTuong','TenDoiTuong','SoTien','PhanBoMode','MaCN','ChungTu','TrangThai']);
    select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb) into v_rows from (
      select p.created_at, jsonb_build_object(
        'MaThanhToan', p.ma_thanh_toan, 'NgayThanhToan', to_char(p.ngay_thanh_toan, 'YYYY-MM-DD'),
        'MaDoiTuong', dt.ma_doi_tuong, 'TenDoiTuong', p.ten_doi_tuong, 'SoTien', p.so_tien,
        'PhanBoMode', p.phan_bo_mode, 'MaCN', p.ma_cn, 'ChungTu', p.chung_tu, 'TrangThai', p.trang_thai
      ) as x
      from payments p left join doi_tuong dt on dt.id = p.doi_tuong_id
      where (v_ma is null or dt.ma_doi_tuong = v_ma)
        and (v_from is null or p.ngay_thanh_toan >= v_from)
        and (v_to is null or p.ngay_thanh_toan <= v_to)
      order by p.created_at desc
      limit v_limit
    ) t;

  elsif p_kind in ('receipt', 'debt', 'approved') then
    v_columns := to_jsonb(array['MaCN','MaDoiTuong','TenDoiTuong','MatHang','SLDat','SLThucNhan','ThanhTienThucNhan','DaThanhToan','TrangThai']);
    select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb) into v_rows from (
      select vd.created_at, jsonb_build_object(
        'MaCN', vd.ma_cn, 'MaDoiTuong', dt.ma_doi_tuong, 'TenDoiTuong', vd.ten_doi_tuong,
        'MatHang', vd.mat_hang, 'SLDat', vd.sl_dat, 'SLThucNhan', vd.sl_thuc_nhan,
        'ThanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'DaThanhToan', vd.da_thanh_toan, 'TrangThai', vd.trang_thai_dong
      ) as x
      from v_debts vd left join doi_tuong dt on dt.id = vd.doi_tuong_id
      where (p_kind <> 'receipt' or vd.is_archived = false)
        and (v_ma is null or dt.ma_doi_tuong = v_ma)
        and (v_status is null or vd.trang_thai_dong ilike '%' || v_status || '%')
        and (v_from is null or coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) >= v_from)
        and (v_to is null or coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) <= v_to)
      order by vd.created_at desc
      limit v_limit
    ) t;

  else -- 'proposal' (default)
    v_columns := to_jsonb(array['MaDeXuat','NgayDeXuat','MaDoiTuong','TenDoiTuong','NoiDung','DieuKhoanTT','TrangThai','NguoiTao']);
    select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb) into v_rows from (
      select p.created_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'MaDoiTuong', dt.ma_doi_tuong, 'TenDoiTuong', p.ten_doi_tuong, 'NoiDung', p.noi_dung,
        'DieuKhoanTT', p.dieu_khoan_tt, 'TrangThai', p.trang_thai,
        'NguoiTao', (select pr.name from profiles pr where pr.id = p.nguoi_tao)
      ) as x
      from proposals p left join doi_tuong dt on dt.id = p.doi_tuong_id
      where (v_ma is null or dt.ma_doi_tuong = v_ma)
        and (v_status is null or p.trang_thai ilike '%' || v_status || '%')
        and (v_from is null or p.ngay_de_xuat >= v_from)
        and (v_to is null or p.ngay_de_xuat <= v_to)
      order by p.created_at desc
      limit v_limit
    ) t;
  end if;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'rows', v_rows, 'columns', v_columns);
end;
$$;

grant execute on function rpc_get_recent(text, jsonb) to authenticated;
