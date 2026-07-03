-- ============================================================================
-- 0055_push_subscriptions.sql  (Đợt I — scaffolding Web Push "thật")
--  Lưu đăng ký push của từng thiết bị để Edge Function gửi thông báo kể cả khi
--  app đóng. Chỉ hoạt động khi đã cấu hình VAPID + Edge Function (xem
--  docs/PUSH_SETUP.md). Nếu chưa cấu hình, app vẫn dùng thông báo hệ thống nội bộ.
-- ============================================================================

create table if not exists push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_push_user on push_subscriptions (user_id);
alter table push_subscriptions enable row level security;
revoke all on push_subscriptions from anon, authenticated;

create or replace function rpc_save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Chưa đăng nhập.'; end if;
  if nullif(trim(coalesce(p_endpoint,'')),'') is null then raise exception 'Thiếu endpoint.'; end if;
  insert into push_subscriptions (user_id, endpoint, p256dh, auth)
  values (v_me, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
  return jsonb_build_object('ok', true);
end; $$;

create or replace function rpc_delete_push_subscription(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end; $$;

grant execute on function rpc_save_push_subscription(text, text, text) to authenticated;
grant execute on function rpc_delete_push_subscription(text) to authenticated;
