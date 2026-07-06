-- ============================================================================
-- 0065_private_business_attachments.sql
--  Vertical slice 4: Move new business evidence files to private storage.
--   * Keep the legacy public "attachments" bucket untouched for old URLs.
--   * New quote / VAT / BBGN / receipt / payment-proof files use a private
--     "business-attachments" bucket.
--   * Storage reads and signed URL creation are guarded by workflow-aware
--     database predicates instead of broad authenticated access.
-- ============================================================================

create or replace function business_attachment_json_has_path(p_files jsonb, p_object_name text) returns boolean
language sql stable as $$
  select exists (
    select 1
    from jsonb_array_elements(
      case
        when jsonb_typeof(coalesce(p_files, '[]'::jsonb)) = 'array' then coalesce(p_files, '[]'::jsonb)
        else '[]'::jsonb
      end
    ) as f(file)
    where f.file->>'bucket' = 'business-attachments'
      and f.file->>'path' = p_object_name
  );
$$;

create or replace function can_insert_business_attachment(p_object_name text) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_owner text;
  v_kind text;
begin
  select * into v_actor from profiles where id = auth.uid() and status = 'Hoạt động';
  if v_actor is null then return false; end if;

  v_owner := split_part(coalesce(p_object_name, ''), '/', 1);
  v_kind := split_part(coalesce(p_object_name, ''), '/', 2);
  return v_owner = v_actor.id::text
     and (
       v_actor.role = 'Admin'
       or (
         v_kind = 'bao-gia'
         and exists (select 1 from role_permissions where role = v_actor.role and permission = 'proposal:create')
       )
       or (
         v_kind = 'nghiem-thu'
         and exists (select 1 from role_permissions where role = v_actor.role and permission = 'receipt:update')
       )
       or (
         v_kind = 'chi-tien'
         and exists (select 1 from role_permissions where role = v_actor.role and permission = 'payment:execute')
       )
     );
end;
$$;

create or replace function can_read_business_attachment(p_object_name text) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
begin
  select * into v_actor from profiles where id = auth.uid() and status = 'Hoạt động';
  if v_actor is null or nullif(trim(coalesce(p_object_name, '')), '') is null then
    return false;
  end if;

  if v_actor.role = 'Admin' then
    return true;
  end if;

  -- Quote attachments on proposals: creator, leadership approvers, KTTH
  -- oversight, and department heads for their own department.
  if exists (
    select 1
    from proposals p
    where business_attachment_json_has_path(p.attachments, p_object_name)
      and (
        p.nguoi_tao = v_actor.id
        or v_actor.role in ('ChuTich', 'TongGiamDoc', 'LanhDao')
        or v_actor.role = 'KeToanCongNo'
        or (v_actor.role = 'TruongPhong' and v_actor.bo_phan is not null and p.bo_phan = v_actor.bo_phan)
      )
  ) then
    return true;
  end if;

  -- Receipt / VAT / BBGN files on debts: proposal creator, KTTH, cashier when
  -- the item is in their review/paid workflow, and leadership when reviewing a
  -- payment request that includes the debt.
  if exists (
    select 1
    from debts d
    left join proposals p on p.id = d.proposal_id
    where business_attachment_json_has_path(d.nghiem_thu_files, p_object_name)
      and (
        p.nguoi_tao = v_actor.id
        or v_actor.role = 'KeToanCongNo'
        or (
          v_actor.role = 'ThuQuy'
          and (
            (d.sl_thuc_nhan is not null and d.cong_no_confirmed = false and not d.prepay and d.cho_bo_sung = false)
            or exists (
              select 1
              from payment_request_lines l
              join payment_requests pr on pr.id = l.request_id
              where l.debt_id = d.id and pr.trang_thai in ('Đã duyệt', 'Đã chi')
            )
          )
        )
        or (
          v_actor.role in ('ChuTich', 'TongGiamDoc', 'LanhDao')
          and exists (
            select 1
            from payment_request_lines l
            join payment_requests pr on pr.id = l.request_id
            where l.debt_id = d.id and pr.trang_thai in ('Chờ duyệt', 'Đã duyệt', 'Đã chi')
          )
        )
      )
  ) then
    return true;
  end if;

  -- Cashier payment proof stored on payment request lines.
  if exists (
    select 1
    from payment_request_lines l
    left join debts d on d.id = l.debt_id
    left join proposals p on p.id = d.proposal_id
    where business_attachment_json_has_path(l.proof_files, p_object_name)
      and (
        v_actor.role in ('ThuQuy', 'KeToanCongNo', 'ChuTich', 'TongGiamDoc', 'LanhDao')
        or (l.paid = true and p.nguoi_tao = v_actor.id)
      )
  ) then
    return true;
  end if;

  -- Cashier payment proof duplicated on payments for accounting/history views.
  if exists (
    select 1
    from payments pm
    left join debts d on d.ma_cn = pm.ma_cn
    left join proposals p on p.id = d.proposal_id
    where business_attachment_json_has_path(pm.proof_files, p_object_name)
      and (
        v_actor.role in ('ThuQuy', 'KeToanCongNo', 'ChuTich', 'TongGiamDoc', 'LanhDao')
        or p.nguoi_tao = v_actor.id
      )
  ) then
    return true;
  end if;

  return false;
end;
$$;

create or replace function rpc_check_business_attachment_access(p_path text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not can_read_business_attachment(p_path) then
    raise exception 'Bạn không có quyền mở tệp đính kèm này.';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function business_attachment_json_has_path(jsonb, text) to authenticated;
grant execute on function can_insert_business_attachment(text) to authenticated;
grant execute on function can_read_business_attachment(text) to authenticated;
grant execute on function rpc_check_business_attachment_access(text) to authenticated;

do $$
begin
  begin
    insert into storage.buckets (id, name, public)
    values ('business-attachments', 'business-attachments', false)
    on conflict (id) do update set public = false;
  exception when others then
    raise notice 'skip private business attachment bucket setup: %', sqlerrm;
  end;

  begin
    execute $q$drop policy if exists business_att_insert on storage.objects$q$;
    execute $q$create policy business_att_insert on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'business-attachments'
        and can_insert_business_attachment(name)
      )$q$;
  exception when others then
    raise notice 'skip private business attachment insert policy: %', sqlerrm;
  end;

  begin
    execute $q$drop policy if exists business_att_select on storage.objects$q$;
    execute $q$create policy business_att_select on storage.objects
      for select to authenticated
      using (
        bucket_id = 'business-attachments'
        and can_read_business_attachment(name)
      )$q$;
  exception when others then
    raise notice 'skip private business attachment select policy: %', sqlerrm;
  end;
end $$;
