-- ============================================================================
-- 0031_chat.sql — Chat nội bộ 1-1 (cơ bản, phục vụ nghiệp vụ mua hàng/công nợ)
-- messages: from_user, to_user, body, attachments (jsonb), ref_ma (phiếu ĐX), read
-- ============================================================================

create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references profiles (id) on delete cascade,
  to_user uuid not null references profiles (id) on delete cascade,
  body text,
  attachments jsonb not null default '[]'::jsonb,
  ref_ma text,
  da_doc boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_msg_pair on messages (from_user, to_user, created_at);
create index if not exists idx_msg_to on messages (to_user, da_doc);
alter table messages enable row level security;
revoke all on messages from anon, authenticated;

-- Danh bạ: mọi tài khoản Hoạt động (trừ mình) + tin cuối + số chưa đọc
create or replace function rpc_list_contacts() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_rows jsonb;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  select coalesce(jsonb_agg(x order by (x->>'lastAt') desc nulls last, x->>'ten'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', p.id, 'ten', p.name, 'vaiTro', p.role,
      'unread', (select count(*) from messages m where m.to_user = v_me and m.from_user = p.id and not m.da_doc),
      'lastAt', (select max(created_at) from messages m where (m.from_user=v_me and m.to_user=p.id) or (m.from_user=p.id and m.to_user=v_me)),
      'lastBody', (select body from messages m where (m.from_user=v_me and m.to_user=p.id) or (m.from_user=p.id and m.to_user=v_me) order by created_at desc limit 1)
    ) as x
    from profiles p where p.id <> v_me and p.status = 'Hoạt động'
  ) t;
  return jsonb_build_object('ok', true, 'unreadTotal', (select count(*) from messages where to_user = v_me and not da_doc), 'rows', v_rows);
end; $$;

create or replace function rpc_get_conversation(p_with uuid, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_rows jsonb;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  update messages set da_doc = true where to_user = v_me and from_user = p_with and not da_doc;
  select coalesce(jsonb_agg(x order by created_at asc), '[]'::jsonb) into v_rows
  from (
    select created_at, jsonb_build_object(
      'fromMe', (from_user = v_me), 'body', body, 'attachments', attachments, 'refMa', ref_ma,
      'time', to_char(created_at, 'DD/MM HH24:MI')
    ) as x
    from messages
    where (from_user = v_me and to_user = p_with) or (from_user = p_with and to_user = v_me)
    order by created_at desc limit least(greatest(coalesce(p_limit,100),1),300)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

create or replace function rpc_send_message(p_to uuid, p_body text, p_attachments jsonb default '[]'::jsonb, p_ref_ma text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid(); v_name text; v_id uuid;
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  if p_to is null then raise exception 'Thiếu người nhận.'; end if;
  if nullif(trim(coalesce(p_body,'')),'') is null and coalesce(jsonb_array_length(p_attachments),0) = 0 then
    raise exception 'Tin nhắn trống.';
  end if;
  select name into v_name from profiles where id = v_me;
  insert into messages (from_user, to_user, body, attachments, ref_ma)
  values (v_me, p_to, nullif(trim(coalesce(p_body,'')),''), coalesce(p_attachments,'[]'::jsonb), nullif(trim(coalesce(p_ref_ma,'')),''))
  returning id into v_id;
  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  values (p_to, 'chat', 'Tin nhắn mới từ ' || coalesce(v_name,''), left(coalesce(p_body,'[tệp đính kèm]'),120), 'chat', v_me::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

grant execute on function rpc_list_contacts() to authenticated;
grant execute on function rpc_get_conversation(uuid, int) to authenticated;
grant execute on function rpc_send_message(uuid, text, jsonb, text) to authenticated;
