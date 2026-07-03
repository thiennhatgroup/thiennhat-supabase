-- ============================================================================
-- 0054_chat_groups.sql  (Đợt D)
--  Nhóm chat: tạo nhóm, thêm thành viên từ danh bạ, đặt tên; nhắn tin nhóm.
-- ============================================================================

create table if not exists chat_groups (
  id uuid primary key default gen_random_uuid(),
  ten text not null,
  created_by uuid references profiles (id),
  created_at timestamptz not null default now()
);
create table if not exists chat_group_members (
  group_id uuid not null references chat_groups (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  primary key (group_id, user_id)
);
create table if not exists chat_group_reads (
  group_id uuid not null references chat_groups (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table messages add column if not exists group_id uuid references chat_groups (id) on delete cascade;
alter table messages alter column to_user drop not null;
create index if not exists idx_msg_group on messages (group_id, created_at);

alter table chat_groups enable row level security;
alter table chat_group_members enable row level security;
alter table chat_group_reads enable row level security;
revoke all on chat_groups, chat_group_members, chat_group_reads from anon, authenticated;

create or replace function rpc_create_chat_group(p_ten text, p_members jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_ten text := nullif(trim(coalesce(p_ten,'')),''); v_gid uuid; v_mid text;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  if v_ten is null then raise exception 'Cần đặt tên nhóm.'; end if;
  insert into chat_groups (ten, created_by) values (v_ten, v_me) returning id into v_gid;
  insert into chat_group_members (group_id, user_id) values (v_gid, v_me) on conflict do nothing;
  for v_mid in select * from jsonb_array_elements_text(coalesce(p_members,'[]'::jsonb)) loop
    if nullif(trim(v_mid),'') is not null then
      insert into chat_group_members (group_id, user_id) values (v_gid, v_mid::uuid) on conflict do nothing;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'id', v_gid);
end; $$;

create or replace function rpc_add_group_members(p_group_id uuid, p_members jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_mid text; v_n int := 0;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  if not exists (select 1 from chat_group_members where group_id = p_group_id and user_id = v_me) then
    raise exception 'Bạn không thuộc nhóm này.'; end if;
  for v_mid in select * from jsonb_array_elements_text(coalesce(p_members,'[]'::jsonb)) loop
    if nullif(trim(v_mid),'') is not null then
      insert into chat_group_members (group_id, user_id) values (p_group_id, v_mid::uuid) on conflict do nothing;
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'added', v_n);
end; $$;

create or replace function rpc_list_chat_groups() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_rows jsonb;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  select coalesce(jsonb_agg(x order by (x->>'lastAt') desc nulls last, x->>'ten'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', g.id, 'ten', g.ten,
      'soTv', (select count(*) from chat_group_members where group_id = g.id),
      'lastAt', (select max(created_at) from messages m where m.group_id = g.id),
      'lastBody', (select body from messages m where m.group_id = g.id order by created_at desc limit 1),
      'unread', (select count(*) from messages m where m.group_id = g.id and m.from_user <> v_me
                 and m.created_at > coalesce((select last_read_at from chat_group_reads r where r.group_id = g.id and r.user_id = v_me), 'epoch'::timestamptz))
    ) as x
    from chat_groups g join chat_group_members mm on mm.group_id = g.id and mm.user_id = v_me
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

create or replace function rpc_get_group_conversation(p_group_id uuid, p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_rows jsonb; v_ten text;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  if not exists (select 1 from chat_group_members where group_id = p_group_id and user_id = v_me) then
    raise exception 'Bạn không thuộc nhóm này.'; end if;
  insert into chat_group_reads (group_id, user_id, last_read_at) values (p_group_id, v_me, now())
    on conflict (group_id, user_id) do update set last_read_at = now();
  select ten into v_ten from chat_groups where id = p_group_id;
  select coalesce(jsonb_agg(x order by created_at asc), '[]'::jsonb) into v_rows
  from (
    select created_at, jsonb_build_object(
      'fromMe', (from_user = v_me), 'senderName', (select name from profiles where id = from_user),
      'body', body, 'attachments', attachments, 'refMa', ref_ma, 'time', to_char(created_at, 'DD/MM HH24:MI')
    ) as x
    from messages where group_id = p_group_id
    order by created_at desc limit least(greatest(coalesce(p_limit,200),1),400)
  ) t;
  return jsonb_build_object('ok', true, 'ten', v_ten, 'rows', v_rows);
end; $$;

create or replace function rpc_send_group_message(p_group_id uuid, p_body text, p_attachments jsonb default '[]'::jsonb, p_ref_ma text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_name text; v_ten text; v_id uuid;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  if not exists (select 1 from chat_group_members where group_id = p_group_id and user_id = v_me) then
    raise exception 'Bạn không thuộc nhóm này.'; end if;
  if nullif(trim(coalesce(p_body,'')),'') is null and coalesce(jsonb_array_length(p_attachments),0) = 0 then
    raise exception 'Tin nhắn trống.'; end if;
  select name into v_name from profiles where id = v_me;
  select ten into v_ten from chat_groups where id = p_group_id;
  insert into messages (from_user, group_id, body, attachments, ref_ma)
  values (v_me, p_group_id, nullif(trim(coalesce(p_body,'')),''), coalesce(p_attachments,'[]'::jsonb), nullif(trim(coalesce(p_ref_ma,'')),''))
  returning id into v_id;
  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select user_id, 'chat_group', 'Tin nhắn nhóm ' || coalesce(v_ten,''), coalesce(v_name,'') || ': ' || left(coalesce(p_body,'[tệp]'),100), 'chat', p_group_id::text
  from chat_group_members where group_id = p_group_id and user_id <> v_me;
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

grant execute on function rpc_create_chat_group(text, jsonb) to authenticated;
grant execute on function rpc_add_group_members(uuid, jsonb) to authenticated;
grant execute on function rpc_list_chat_groups() to authenticated;
grant execute on function rpc_get_group_conversation(uuid, int) to authenticated;
grant execute on function rpc_send_group_message(uuid, text, jsonb, text) to authenticated;
