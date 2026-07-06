-- ============================================================================
-- 0064_secure_push_sender.sql
--  Add a shared-secret handshake between the notifications trigger and the
--  send-push Edge Function. If the database secret is not configured, skip the
--  outbound call instead of invoking an unauthenticated service-role function.
-- ============================================================================

create extension if not exists pg_net;

create or replace function tg_push_on_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_secret text;
begin
  begin
    select nullif(trim(decrypted_secret), '')
      into v_secret
      from vault.decrypted_secrets
     where name = 'push_webhook_secret'
     limit 1;
  exception
    when invalid_schema_name or undefined_table or undefined_column then
      v_secret := null;
  end;

  if v_secret is null then
    v_secret := nullif(trim(current_setting('app.push_webhook_secret', true)), '');
  end if;

  if v_secret is null then
    raise warning 'Skipping send-push webhook: push_webhook_secret is not configured.';
    return NEW;
  end if;

  perform net.http_post(
    url := 'https://nsxvasvceslhhvgjkedh.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-push-webhook-secret', v_secret
    ),
    body := jsonb_build_object('record', to_jsonb(NEW))
  );
  return NEW;
end $$;

drop trigger if exists push_on_notify on notifications;
create trigger push_on_notify after insert on notifications
  for each row execute function tg_push_on_notify();
