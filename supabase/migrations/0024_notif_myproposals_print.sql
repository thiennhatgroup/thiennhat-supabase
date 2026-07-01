-- ============================================================================
-- 0024_notif_myproposals_print.sql
--   rpc_get_notifications / mark read      -> the bell inbox
--   rpc_get_my_proposals                   -> "đề xuất của tôi" dashboard
--   rpc_get_printable_proposals            -> approved (+accepted) proposals with
--                                             lines + supplier bank, for the two
--                                             Excel exports.
-- ============================================================================

create or replace function rpc_get_notifications(p_limit int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_rows jsonb; v_unread int;
begin
  if v_uid is null then raise exception 'Chưa đăng nhập.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'loai', loai, 'tieuDe', tieu_de, 'noiDung', noi_dung,
    'manHinh', man_hinh, 'refId', ref_id, 'daDoc', da_doc,
    'thoiGian', to_char(created_at, 'DD/MM HH24:MI')
  ) order by created_at desc), '[]'::jsonb) into v_rows
  from (select * from notifications where to_user = v_uid order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) s;
  select count(*) into v_unread from notifications where to_user = v_uid and da_doc = false;
  return jsonb_build_object('ok', true, 'unread', v_unread, 'rows', v_rows);
end;
$$;

create or replace function rpc_mark_notification_read(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update notifications set da_doc = true where id = p_id and to_user = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function rpc_mark_all_notifications_read() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update notifications set da_doc = true where to_user = auth.uid() and da_doc = false;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function rpc_get_my_proposals(p_limit int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_rows jsonb;
begin
  if v_uid is null then raise exception 'Chưa đăng nhập.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'MaDeXuat', ma_de_xuat, 'LoaiDeXuat', loai_de_xuat,
    'Ngay', to_char(ngay_de_xuat, 'YYYY-MM-DD'), 'TenDoiTuong', ten_doi_tuong,
    'TrangThai', trang_thai, 'GhiChu', ghi_chu,
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0)
  ) order by created_at desc), '[]'::jsonb) into v_rows
  from (select * from proposals where nguoi_tao = v_uid order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) p;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- Approved proposals with lines + supplier bank, for printing. p_only_accepted
-- limits to proposals whose obligations have been accepted (nghiệm thu).
create or replace function rpc_get_printable_proposals(p_only_accepted boolean default true) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('recent:read');
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

grant execute on function rpc_get_notifications(int) to authenticated;
grant execute on function rpc_mark_notification_read(uuid) to authenticated;
grant execute on function rpc_mark_all_notifications_read() to authenticated;
grant execute on function rpc_get_my_proposals(int) to authenticated;
grant execute on function rpc_get_printable_proposals(boolean) to authenticated;
