-- ============================================================================
-- 0071_department_assignment_admin_fields.sql
--  Reconciled remainder of the original 0064_department_assignment_reliable.sql
--  draft (that file is intentionally left unapplied in the repo — see its
--  header comment).
--
--  What's actually still missing in production: Admin has no way to set a
--  user's or proposer's department_id (UUID), only the free-text bo_phan.
--  The departments table, department_id columns on profiles/proposals, and
--  all department-aware proposal/oversight/catalog RPCs were already added by
--  0065_proposal_ownership_visibility.sql and 0068_split_overbroad_permissions.sql.
--
--  Deliberately NOT touching (already correct/live, and older than this):
--   * rpc_add_department, rpc_bootstrap, rpc_list_catalog, rpc_admin_list_users
--     -- superseded by 0068_split_overbroad_permissions.sql.
--   * rpc_create_proposal, rpc_update_proposal, rpc_get_proposal,
--     rpc_submit_proposal, rpc_oversight, rpc_cancel_proposal,
--     rpc_oversight_proposal_detail, rpc_bounce_proposal
--     -- superseded by 0065_proposal_ownership_visibility.sql, which added the
--     ownership/department-visibility checks the original 0064 draft predates
--     and lacks. Reapplying the 0064 draft's versions would have silently
--     removed those checks from production.
--
--  Note: this migration assumes the `departments` table already exists (it
--  does in production, created out-of-band before migration tracking caught
--  up). The `create table if not exists` below is kept only so a from-scratch
--  replay of this migration history doesn't break -- but note that a genuine
--  from-scratch replay would still hit this same table before it's needed, at
--  migration 0065 (proposal_ownership_visibility), since that runs earlier
--  and references departments(id) via foreign key. That's pre-existing
--  ordering debt in this migration history, not introduced here, and is out
--  of scope for this fix.
-- ============================================================================

create table if not exists departments (
  id uuid primary key default gen_random_uuid(),
  ten text unique not null,
  created_at timestamptz not null default now()
);
alter table departments enable row level security;
revoke all on departments from anon, authenticated;

alter table proposers add column if not exists department_id uuid references departments (id);
create index if not exists idx_proposers_department on proposers (department_id);

drop function if exists rpc_add_proposer(text, text);
create or replace function rpc_add_proposer(p_ten text, p_bo_phan text default null, p_department_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ten text := nullif(trim(coalesce(p_ten,'')),'');
  v_department_id uuid := p_department_id;
  v_department_name text := nullif(trim(coalesce(p_bo_phan,'')),'');
  v_before proposers;
  v_after proposers;
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then raise exception 'Cần nhập tên người đề nghị.'; end if;

  if v_department_id is not null then
    select ten into v_department_name from departments where id = v_department_id;
    if v_department_name is null then raise exception 'Bộ phận không tồn tại trong danh mục.'; end if;
  elsif v_department_name is not null then
    select id, ten into v_department_id, v_department_name
    from departments
    where normalize_text(ten) = normalize_text(v_department_name)
    order by created_at, ten
    limit 1;
    if v_department_id is null then raise exception 'Bộ phận "%" chưa có trong danh mục. Hãy thêm bộ phận trước.', p_bo_phan; end if;
  end if;

  select * into v_before from proposers where ten = v_ten;
  insert into proposers (ten, bo_phan, department_id)
  values (v_ten, v_department_name, v_department_id)
  on conflict (ten) do update set bo_phan = excluded.bo_phan, department_id = excluded.department_id
  returning * into v_after;

  if v_before is null then
    perform write_audit(v_actor, 'CREATE_PROPOSER', 'proposers', v_after.id::text, null, to_jsonb(v_after), 'OK', '');
  elsif v_before.bo_phan is distinct from v_after.bo_phan or v_before.department_id is distinct from v_after.department_id then
    perform write_audit(v_actor, 'UPDATE_PROPOSER_DEPARTMENT', 'proposers', v_after.id::text, to_jsonb(v_before), to_jsonb(v_after), 'OK', '');
  end if;

  return jsonb_build_object('ok', true, 'proposers', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'ten', p.ten, 'departmentId', p.department_id, 'boPhan', coalesce(d.ten, p.bo_phan)
    ) order by p.ten), '[]'::jsonb)
    from proposers p
    left join departments d on d.id = p.department_id
  ));
end; $$;

drop function if exists rpc_admin_create_user(text, text, text, text);
create or replace function rpc_admin_create_user(p_email text, p_name text, p_role text, p_pin text, p_department_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor profiles; v_uid uuid := gen_random_uuid();
  v_email text := lower(trim(coalesce(p_email,''))); v_pin text := trim(coalesce(p_pin,''));
  v_department_name text;
begin
  v_actor := require_permission('user:manage');
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'Email không hợp lệ.'; end if;
  if p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if p_role in ('NhanVienMuaHang','TruongPhong') and p_department_id is null then
    raise exception 'Nhân viên mua hàng và Trưởng phòng bắt buộc có bộ phận.';
  end if;
  if p_department_id is not null then
    select ten into v_department_name from departments where id = p_department_id;
    if v_department_name is null then raise exception 'Bộ phận không tồn tại trong danh mục.'; end if;
  end if;
  if length(v_pin) < 4 then raise exception 'Mã PIN cần ít nhất 4 ký tự.'; end if;
  if exists (select 1 from auth.users where email = v_email) then raise exception 'Email % đã tồn tại.', v_email; end if;
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
    crypt('tn-pin::' || v_pin, gen_salt('bf')), now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', coalesce(nullif(trim(p_name),''), v_email)),
    false, '', '', '', ''
  );
  insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid::text, v_uid, jsonb_build_object('sub', v_uid::text, 'email', v_email), 'email', now(), now(), now());
  insert into profiles (id, email, name, role, status, department_id, bo_phan)
  values (v_uid, v_email, coalesce(nullif(trim(p_name),''), v_email), p_role, 'Hoạt động', p_department_id, v_department_name);
  perform write_audit(v_actor, 'CREATE_USER', 'profiles', v_uid::text, null,
    jsonb_build_object('email', v_email, 'role', p_role, 'departmentId', p_department_id, 'boPhan', v_department_name), 'OK', '');
  return jsonb_build_object('ok', true, 'id', v_uid, 'email', v_email);
end; $$;

drop function if exists rpc_admin_update_user(uuid, text, text, text, text);
create or replace function rpc_admin_update_user(
  p_id uuid,
  p_role text default null,
  p_status text default null,
  p_name text default null,
  p_bo_phan text default null,
  p_department_id uuid default null
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_before jsonb; v_current profiles; v_row profiles;
  v_role text; v_status text; v_department_id uuid; v_department_name text;
begin
  v_actor := require_permission('user:manage');
  select * into v_current from profiles where id = p_id;
  if v_current is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  v_before := to_jsonb(v_current);

  v_role := coalesce(nullif(trim(coalesce(p_role,'')),''), v_current.role);
  v_status := coalesce(nullif(trim(coalesce(p_status,'')),''), v_current.status);
  if v_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if v_status not in ('Hoạt động','Ngừng') then raise exception 'Trạng thái không hợp lệ.'; end if;

  v_department_id := v_current.department_id;
  v_department_name := v_current.bo_phan;

  if p_department_id is not null then
    v_department_id := p_department_id;
    select ten into v_department_name from departments where id = v_department_id;
    if v_department_name is null then raise exception 'Bộ phận không tồn tại trong danh mục.'; end if;
  elsif p_bo_phan is not null then
    v_department_name := nullif(trim(coalesce(p_bo_phan,'')), '');
    if v_department_name is null then
      v_department_id := null;
    else
      select id, ten into v_department_id, v_department_name
      from departments
      where normalize_text(ten) = normalize_text(v_department_name)
      order by created_at, ten
      limit 1;
      if v_department_id is null then raise exception 'Bộ phận "%" chưa có trong danh mục. Hãy thêm bộ phận trước.', p_bo_phan; end if;
    end if;
  end if;

  if v_status = 'Hoạt động' and v_role in ('NhanVienMuaHang','TruongPhong') and v_department_id is null then
    raise exception 'Nhân viên mua hàng và Trưởng phòng bắt buộc có bộ phận trước khi tài khoản hoạt động.';
  end if;

  update profiles set
    role = v_role,
    status = v_status,
    name = coalesce(nullif(trim(coalesce(p_name,'')),''), name),
    department_id = v_department_id,
    bo_phan = v_department_name
  where id = p_id returning * into v_row;
  perform write_audit(v_actor, 'UPDATE_USER', 'profiles', p_id::text, v_before, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'id', p_id);
end; $$;

grant execute on function rpc_add_proposer(text, text, uuid) to authenticated;
grant execute on function rpc_admin_create_user(text, text, text, text, uuid) to authenticated;
grant execute on function rpc_admin_update_user(uuid, text, text, text, text, uuid) to authenticated;
