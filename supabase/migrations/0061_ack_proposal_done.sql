-- ============================================================================
-- 0061_ack_proposal_done.sql
--  Khoản ĐÃ CHI (hết vòng đời): NVMH kiểm tra xong bấm "Lưu" -> đánh dấu hoàn tất
--  và ẩn khỏi "Đề xuất của tôi" (không popup, ghi thẳng DB).
-- ============================================================================

alter table proposals add column if not exists nvmh_done boolean not null default false;
alter table proposals add column if not exists nvmh_done_at timestamptz;

create or replace function rpc_ack_proposal_done(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'Chưa đăng nhập.'; end if;
  update proposals set nvmh_done = true, nvmh_done_at = now()
  where ma_de_xuat = p_ma_de_xuat and nguoi_tao = v_uid
  returning id into v_id;
  if v_id is null then raise exception 'Không tìm thấy phiếu của bạn.'; end if;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;
grant execute on function rpc_ack_proposal_done(text) to authenticated;

-- "Đề xuất của tôi": ẩn phiếu đã bấm Lưu (nvmh_done), kèm ảnh chuyển khoản.
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
  from (select * from proposals where nguoi_tao = v_uid and nvmh_done = false
        order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) p;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
grant execute on function rpc_get_my_proposals(int) to authenticated;
