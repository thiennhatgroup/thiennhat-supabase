-- ============================================================================
-- 0004_permissions.sql
-- Permission helpers, mirroring requireWebPermission_() / WEB_ROLE_PERMISSIONS
-- in webapp.gs. Every RPC below calls require_permission(...) as its first
-- statement, exactly like every apiXxx() function in webapp.gs calls
-- requireWebPermission_(token, 'perm') first.
-- ============================================================================

create or replace function has_permission(p_role text, p_permission text) returns boolean
language sql stable as $$
  select p_role = 'Admin' or exists (
    select 1 from role_permissions where role = p_role and permission = p_permission
  );
$$;

-- Returns the calling user's profile row after checking status + permission.
-- Raises a Vietnamese error message identical in spirit to the GAS version
-- so the frontend can show it directly.
create or replace function require_permission(p_permission text) returns profiles
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile profiles;
begin
  select * into v_profile from profiles where id = auth.uid();
  if v_profile is null then
    raise exception 'Tài khoản chưa được cấp quyền truy cập hệ thống. Hãy liên hệ Admin để tạo hồ sơ trong bảng profiles.';
  end if;
  if v_profile.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;
  if not has_permission(v_profile.role, p_permission) then
    raise exception 'Vai trò % không có quyền thực hiện thao tác này.', v_profile.role;
  end if;
  return v_profile;
end;
$$;

create or replace function write_audit(
  p_actor profiles,
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_before jsonb,
  p_after jsonb,
  p_result text default 'OK',
  p_message text default ''
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into audit_log (log_id, actor_id, actor_email, actor_name, role, action, entity_type, entity_id, before_json, after_json, result, message)
  values (next_code('LOG'), p_actor.id, p_actor.email, p_actor.name, p_actor.role, p_action, p_entity_type, p_entity_id, p_before, p_after, coalesce(p_result, 'OK'), coalesce(p_message, ''));
exception when others then
  -- Never let an audit-log failure block the real business transaction,
  -- mirroring the try/catch + console.log('Không ghi được WEB_AUDIT_LOG...')
  -- fallback in webapp.gs.
  raise notice 'audit log write failed: %', sqlerrm;
end;
$$;

-- Finds or creates a doi_tuong row, mirroring ensureDoiTuongFromPayload_().
create or replace function ensure_doi_tuong(
  p_ma text,
  p_ten text,
  p_loai text default 'NCC',
  p_mst text default null,
  p_dia_chi text default null,
  p_contact text default null,
  p_dieu_khoan text default null
) returns doi_tuong
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_row doi_tuong;
begin
  if p_ma is not null and length(trim(p_ma)) > 0 then
    select * into v_row from doi_tuong where ma_doi_tuong = trim(p_ma);
    if found then return v_row; end if;
  end if;

  if p_ten is not null and length(trim(p_ten)) > 0 then
    select * into v_row from doi_tuong where normalize_text(ten_doi_tuong) = normalize_text(p_ten);
    if found then return v_row; end if;
  end if;

  if p_ten is null or length(trim(p_ten)) = 0 then
    raise exception 'Cần chọn hoặc nhập tên đối tượng.';
  end if;

  insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, dia_chi, contact, dieu_khoan_tt_mac_dinh)
  values (next_code('DT'), trim(p_ten), coalesce(p_loai, 'NCC'), p_mst, p_dia_chi, p_contact, p_dieu_khoan)
  returning * into v_row;
  return v_row;
end;
$$;

-- Finds or creates a materials row by name, so a freehand "gõ mặt hàng mới"
-- entry from the frontend becomes part of the reusable dropdown list next
-- time, mirroring the ➕ "Nhập mặt hàng mới" combo behaviour in Index.html.
create or replace function ensure_material(p_ten text, p_dvt text default null) returns materials
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_row materials;
begin
  if p_ten is null or length(trim(p_ten)) = 0 then
    raise exception 'Cần nhập tên vật tư/hàng hoá.';
  end if;
  select * into v_row from materials where normalize_text(ten) = normalize_text(p_ten);
  if found then return v_row; end if;
  insert into materials (ten, dvt) values (trim(p_ten), p_dvt) returning * into v_row;
  return v_row;
end;
$$;

-- Parses a VAT rate that may arrive as 0.08, 8, or "8%" (mirrors vatRate_()
-- in webapp.gs: values < 1 are treated as already-a-fraction, values >= 1
-- are treated as a percentage).
create or replace function parse_vat_rate(p_vat text) returns numeric
language plpgsql immutable as $$
declare
  v_clean text;
  v_num numeric;
begin
  if p_vat is null or trim(p_vat) = '' then return 0; end if;
  v_clean := replace(trim(p_vat), '%', '');
  v_clean := replace(v_clean, ',', '.');
  begin
    v_num := v_clean::numeric;
  exception when others then
    return 0;
  end;
  if v_num < 1 then return v_num; end if;
  return v_num / 100;
end;
$$;

-- Parses a number that may contain Vietnamese/English thousands separators
-- (mirrors toNumberOrBlank_()). Returns null if there is nothing numeric.
create or replace function parse_number(p_val text) returns numeric
language plpgsql immutable as $$
declare
  v_clean text;
begin
  if p_val is null or trim(p_val) = '' then return null; end if;
  v_clean := regexp_replace(trim(p_val), '[\s₫đvndVNĐ]', '', 'g');
  if v_clean = '' then return null; end if;
  if v_clean ~ '^-?\d{1,3}(\.\d{3})+(,\d+)?$' then
    v_clean := replace(v_clean, '.', '');
    v_clean := replace(v_clean, ',', '.');
  else
    v_clean := replace(v_clean, ',', '');
  end if;
  begin
    return v_clean::numeric;
  exception when others then
    return null;
  end;
end;
$$;

grant execute on function has_permission(text, text) to authenticated;
