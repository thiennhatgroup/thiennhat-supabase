-- ============================================================================
-- 0041_bootstrap_dvt.sql
--  rpc_bootstrap trả thêm 'vatTuInfo' = [{ten, dvt}] để form Nhập báo giá tự điền
--  ĐVT theo mặt hàng đã chọn. Giữ nguyên 'vatTu' (mảng tên) để không phá code cũ.
-- ============================================================================

create or replace function rpc_bootstrap() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile profiles;
  v_perms jsonb;
begin
  select * into v_profile from profiles where id = auth.uid();
  if v_profile is null then
    raise exception 'Tài khoản chưa được cấp quyền truy cập hệ thống. Hãy liên hệ Admin để tạo hồ sơ trong bảng profiles.';
  end if;
  if v_profile.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;

  if v_profile.role = 'Admin' then
    v_perms := to_jsonb(array['*']::text[]);
  else
    select coalesce(jsonb_agg(permission), '[]'::jsonb) into v_perms
    from role_permissions where role = v_profile.role;
  end if;

  return jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object('email', v_profile.email, 'name', v_profile.name, 'role', v_profile.role),
    'doiTuong', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'MaDoiTuong', ma_doi_tuong,
        'TenDoiTuong', ten_doi_tuong,
        'DieuKhoanTT_MacDinh', dieu_khoan_tt_mac_dinh
      ) order by ten_doi_tuong), '[]'::jsonb)
      from doi_tuong where trang_thai = 'Hoạt động'
    ),
    'vatTu', (
      select coalesce(jsonb_agg(ten order by ten), '[]'::jsonb) from materials
    ),
    'vatTuInfo', (
      select coalesce(jsonb_agg(jsonb_build_object('ten', ten, 'dvt', dvt) order by ten), '[]'::jsonb) from materials
    ),
    'permissions', v_perms
  );
end;
$$;

grant execute on function rpc_bootstrap() to authenticated;
