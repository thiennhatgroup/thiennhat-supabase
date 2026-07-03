-- ============================================================================
-- 0053_oversight_fields.sql  (Đợt A)
--  rpc_oversight trả thêm thời gian submit (tạo), thời gian duyệt, người duyệt
--  để dashboard rà soát hiển thị đủ; bỏ cột NT/TT khó hiểu ở FE.
-- ============================================================================

create or replace function rpc_oversight(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_props jsonb; v_pays jsonb; v_tbp boolean;
begin
  v_actor := require_permission('oversight:read');
  v_tbp := (v_actor.role = 'TruongPhong');

  select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_props
  from (
    select jsonb_build_object(
      'MaDeXuat', p.ma_de_xuat, 'Loai', case when p.loai_de_xuat='TamUng' then 'Tạm ứng' else 'Mua hàng' end,
      'Ngay', to_char(p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', p.nguoi_de_nghi, 'BoPhan', p.bo_phan,
      'TenDoiTuong', p.ten_doi_tuong, 'TrangThai', p.trang_thai, 'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'),
      'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id=p.id),0),
      'DaNghiemThu', exists(select 1 from debts d where d.proposal_id=p.id and d.sl_thuc_nhan is not null),
      'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id=p.id and d.da_thanh_toan>0),
      'ThoiGianTao', to_char(p.created_at,'YYYY-MM-DD HH24:MI'), 'ThoiGianDuyet', to_char(p.approved_at,'YYYY-MM-DD HH24:MI'), 'NguoiDuyet', (select name from profiles where id=p.nguoi_duyet)
    ) as x
    from proposals p
    where (p_from is null or p.ngay_de_xuat >= p_from) and (p_to is null or p.ngay_de_xuat <= p_to)
      and (not v_tbp or (v_actor.bo_phan is not null and p.bo_phan = v_actor.bo_phan))
    order by p.ngay_de_xuat desc limit 500
  ) t;

  if v_tbp then
    v_pays := '[]'::jsonb;   -- Trưởng bộ phận không xem đề xuất thanh toán (thuộc kế toán)
  else
    select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_pays
    from (
      select jsonb_build_object(
        'MaDeXuatTT', pr.ma_de_xuat_tt, 'Ngay', to_char(pr.ngay,'YYYY-MM-DD'), 'TrangThai', pr.trang_thai,
        'NguoiLap', (select name from profiles where id=pr.nguoi_lap),
        'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id=pr.id),0)
      ) as x
      from payment_requests pr
      where (p_from is null or pr.ngay >= p_from) and (p_to is null or pr.ngay <= p_to)
      order by pr.ngay desc limit 500
    ) t;
  end if;

  return jsonb_build_object('ok', true, 'role', v_actor.role, 'proposals', v_props, 'paymentRequests', v_pays);
end; $$;

grant execute on function rpc_oversight(date, date) to authenticated;
