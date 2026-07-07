-- ============================================================================
-- 0072_harden_debt_detail_access.sql
--  Give rpc_get_debt_detail its own explicit detail-read boundary.
--
--  The older active implementation reused receipt/payment evidence visibility.
--  This keeps the same object-scoped access for proposal creators and cashier
--  work queues, while making KTTH/accounting access an explicit permission.
-- ============================================================================

insert into role_permissions (role, permission) values
  ('KeToanCongNo', 'debt:detail:read')
on conflict (role, permission) do nothing;

create or replace function app_can_view_debt_detail(p_debt debts, p_actor profiles)
returns boolean
language plpgsql stable as $$
begin
  if p_actor.id is null or p_actor.status <> 'Hoạt động' then
    return false;
  end if;

  if has_permission(p_actor.role, 'debt:detail:read') then
    return true;
  end if;

  if p_debt.proposal_id is not null and exists (
    select 1
    from proposals p
    where p.id = p_debt.proposal_id
      and p.nguoi_tao = p_actor.id
  ) then
    return true;
  end if;

  if has_permission(p_actor.role, 'payment:execute') and exists (
    select 1
    from payment_request_lines l
    join payment_requests pr on pr.id = l.request_id
    where l.debt_id = p_debt.id
      and pr.trang_thai = 'Đã duyệt'
  ) then
    return true;
  end if;

  if p_actor.role = 'ThuQuy'
     and has_permission(p_actor.role, 'receipt:review')
     and p_debt.sl_thuc_nhan is not null
     and p_debt.cong_no_confirmed = false
     and p_debt.prepay = false
     and p_debt.cho_bo_sung = false then
    return true;
  end if;

  return false;
end;
$$;

create or replace function rpc_get_debt_detail(p_ma_cn text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_debt debts;
  v_j jsonb;
begin
  select * into v_actor
  from profiles
  where id = auth.uid();

  if v_actor is null then
    raise exception 'Chưa đăng nhập.';
  end if;
  if v_actor.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;

  select * into v_debt
  from debts
  where ma_cn = trim(coalesce(p_ma_cn,''));

  if v_debt is null then
    raise exception 'Không tìm thấy khoản công nợ %.', p_ma_cn;
  end if;

  if not app_can_view_debt_detail(v_debt, v_actor) then
    raise exception 'Bạn không có quyền xem chi tiết công nợ này.';
  end if;

  select jsonb_build_object(
    'maCN', vd.ma_cn, 'maDeXuat', p.ma_de_xuat, 'tenDoiTuong', vd.ten_doi_tuong,
    'boPhan', p.bo_phan, 'nguoiDeNghi', p.nguoi_de_nghi,
    'matHang', vd.mat_hang, 'dvt', (select m.dvt from materials m where m.id = vd.material_id),
    'slDat', vd.sl_dat, 'slThucNhan', vd.sl_thuc_nhan, 'donGia', vd.don_gia, 'vatRate', vd.vat_rate,
    'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', vd.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
    'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'ngayNhan', to_char(vd.ngay_nhan,'YYYY-MM-DD'),
    'dieuKhoanTT', vd.dieu_khoan_tt, 'trangThai', vd.trang_thai_dong,
    'soHoaDonVat', d.so_hoa_don_vat,
    'chungTuTypes', coalesce(vd.chung_tu_types,'[]'::jsonb),
    'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb),
    'baoGia', coalesce(p.attachments,'[]'::jsonb),
    'soTk', dt.so_tk_ngan_hang, 'chiNhanh', dt.chi_nhanh_ngan_hang, 'mst', dt.mst,
    'thoiGianDeXuat', to_char(p.created_at,'YYYY-MM-DD HH24:MI'),
    'thoiGianSepDuyet', to_char(p.approved_at,'YYYY-MM-DD HH24:MI'),
    'nguoiSepDuyet', (select name from profiles where id = p.nguoi_duyet),
    'nguoiNghiemThu', (select name from profiles where id = d.nghiem_thu_by),
    'thoiGianNghiemThu', to_char(d.nghiem_thu_at,'YYYY-MM-DD HH24:MI'),
    'ktthDuyet', (select name from profiles where id = d.cong_no_confirmed_by),
    'thoiGianKtthDuyet', to_char(d.cong_no_confirmed_at,'YYYY-MM-DD HH24:MI')
  ) into v_j
  from v_debts vd
  join debts d on d.id = vd.id
  left join doi_tuong dt on dt.id = vd.doi_tuong_id
  left join proposals p on p.id = d.proposal_id
  where d.id = v_debt.id;

  return jsonb_build_object('ok', true, 'debt', v_j);
end;
$$;

revoke all on function app_can_view_debt_detail(debts, profiles) from public, anon, authenticated;
revoke all on function rpc_get_debt_detail(text) from public, anon;
grant execute on function rpc_get_debt_detail(text) to authenticated;
