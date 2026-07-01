-- ============================================================================
-- 0022_admin_users.sql
-- Let an Admin create accounts + assign roles directly from the web app, so
-- there is no need to touch the Supabase dashboard.
--
-- Auth users are created in-database (auth.users + auth.identities) with the
-- same PIN-password model the app already uses: password = 'tn-pin::<PIN>'.
-- email_confirmed_at is set so the account can log in immediately.
--
-- Gated by 'user:manage'; Admin bypasses has_permission() as '*', so no seed
-- row is needed. search_path includes `extensions` so crypt()/gen_salt() from
-- pgcrypto resolve regardless of which schema the extension lives in.
--
-- NOTE: creating rows in the auth schema requires the function owner (the
-- migration role, normally `postgres`) to have privileges on auth.*. If a future
-- Supabase change blocks this, fall back to a service-role Edge Function.
-- ============================================================================

create or replace function rpc_admin_create_user(p_email text, p_name text, p_role text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor profiles;
  v_uid uuid := gen_random_uuid();
  v_email text := lower(trim(coalesce(p_email,'')));
  v_pin text := trim(coalesce(p_pin,''));
  v_pw text;
begin
  v_actor := require_permission('user:manage');
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'Email không hợp lệ.'; end if;
  if p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','LanhDao','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if length(v_pin) < 4 then raise exception 'Mã PIN cần ít nhất 4 ký tự.'; end if;
  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'Email % đã tồn tại.', v_email;
  end if;
  v_pw := 'tn-pin::' || v_pin;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
    crypt(v_pw, gen_salt('bf')), now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', coalesce(nullif(trim(p_name),''), v_email)),
    false, '', '', '', ''
  );

  insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid::text, v_uid,
          jsonb_build_object('sub', v_uid::text, 'email', v_email), 'email', now(), now(), now());

  insert into profiles (id, email, name, role, status)
  values (v_uid, v_email, coalesce(nullif(trim(p_name),''), v_email), p_role, 'Hoạt động');

  perform write_audit(v_actor, 'CREATE_USER', 'profiles', v_uid::text, null,
    jsonb_build_object('email', v_email, 'role', p_role), 'OK', '');
  return jsonb_build_object('ok', true, 'id', v_uid, 'email', v_email);
end;
$$;

create or replace function rpc_admin_list_users() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('user:manage');
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'email', email, 'name', name, 'role', role, 'status', status,
    'createdAt', to_char(created_at, 'YYYY-MM-DD')
  ) order by created_at), '[]'::jsonb) into v_rows from profiles;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_admin_update_user(p_id uuid, p_role text default null, p_status text default null, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_before jsonb; v_row profiles;
begin
  v_actor := require_permission('user:manage');
  select to_jsonb(p) into v_before from profiles p where id = p_id;
  if v_before is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  if p_role is not null and p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','LanhDao','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if p_status is not null and p_status not in ('Hoạt động','Ngừng') then
    raise exception 'Trạng thái không hợp lệ.';
  end if;
  update profiles set
    role = coalesce(nullif(trim(coalesce(p_role,'')),''), role),
    status = coalesce(nullif(trim(coalesce(p_status,'')),''), status),
    name = coalesce(nullif(trim(coalesce(p_name,'')),''), name)
  where id = p_id returning * into v_row;
  perform write_audit(v_actor, 'UPDATE_USER', 'profiles', p_id::text, v_before, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;

create or replace function rpc_admin_reset_pin(p_id uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_actor profiles; v_pin text := trim(coalesce(p_pin,'')); v_email text;
begin
  v_actor := require_permission('user:manage');
  if length(v_pin) < 4 then raise exception 'Mã PIN cần ít nhất 4 ký tự.'; end if;
  select email into v_email from profiles where id = p_id;
  if v_email is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  update auth.users set encrypted_password = crypt('tn-pin::' || v_pin, gen_salt('bf')), updated_at = now()
  where id = p_id;
  perform write_audit(v_actor, 'RESET_PIN', 'profiles', p_id::text, null, jsonb_build_object('email', v_email), 'OK', '');
  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;

grant execute on function rpc_admin_create_user(text, text, text, text) to authenticated;
grant execute on function rpc_admin_list_users() to authenticated;
grant execute on function rpc_admin_update_user(uuid, text, text, text) to authenticated;
grant execute on function rpc_admin_reset_pin(uuid, text) to authenticated;
