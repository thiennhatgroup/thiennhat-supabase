-- ============================================================================
-- 0067_audit_sensitive_actions.sql
--  Slice 6: durable, low-noise audit trail for sensitive actions.
--   * Keep audit rows for at least 12 months; default cleanup keeps 24 months.
--   * Audit permission-checked file-link requests for private/path attachments.
--   * Fill audit gaps for draft submission and department override/catalog work.
--   * Expose a small Admin-only audit review RPC.
-- ============================================================================

create index if not exists idx_audit_log_time_desc on audit_log ("time" desc);
create index if not exists idx_audit_log_action_time on audit_log (action, "time" desc);

comment on table audit_log is
  'Durable audit log for important business changes and sensitive file-link requests. Cleanup keeps audit rows at least 365 days and defaults to 730 days.';

create or replace function app_attachment_json_matches(
  p_files jsonb,
  p_bucket text,
  p_path text,
  p_url text default null
) returns boolean
language sql stable as $$
  select exists (
    select 1
    from jsonb_array_elements(
      case
        when jsonb_typeof(coalesce(p_files, '[]'::jsonb)) = 'array' then coalesce(p_files, '[]'::jsonb)
        else '[]'::jsonb
      end
    ) as f(file)
    where (
      nullif(trim(coalesce(p_path, '')), '') is not null
      and f.file->>'path' = nullif(trim(coalesce(p_path, '')), '')
      and (
        nullif(trim(coalesce(p_bucket, '')), '') is null
        or f.file->>'bucket' = nullif(trim(coalesce(p_bucket, '')), '')
        or (
          nullif(trim(coalesce(p_bucket, '')), '') = 'attachments'
          and coalesce(f.file->>'bucket', 'attachments') = 'attachments'
        )
      )
    )
    or (
      nullif(trim(coalesce(p_url, '')), '') is not null
      and f.file->>'url' = nullif(trim(coalesce(p_url, '')), '')
    )
  );
$$;

create or replace function app_can_access_sensitive_file(
  p_actor profiles,
  p_bucket text,
  p_path text,
  p_url text default null
) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_bucket text := nullif(trim(coalesce(p_bucket, '')), '');
  v_path text := nullif(trim(coalesce(p_path, '')), '');
  v_url text := nullif(trim(coalesce(p_url, '')), '');
  v_private_ok boolean := false;
begin
  if p_actor.id is null then
    return false;
  end if;

  if v_path is null and v_url is null then
    return false;
  end if;

  -- If the private-storage slice is present, reuse its storage predicate so
  -- this audit wrapper stays aligned with signed URL access.
  if v_bucket = 'business-attachments'
     and v_path is not null
     and to_regprocedure('can_read_business_attachment(text)') is not null then
    begin
      execute 'select can_read_business_attachment($1)' into v_private_ok using v_path;
      if coalesce(v_private_ok, false) then
        return true;
      end if;
    exception when others then
      v_private_ok := false;
    end;
  end if;

  if p_actor.role = 'Admin' then
    return true;
  end if;

  -- Quote/proposal attachments.
  if exists (
    select 1
    from proposals p
    where app_attachment_json_matches(p.attachments, v_bucket, v_path, v_url)
      and app_can_view_proposal(p, p_actor)
  ) then
    return true;
  end if;

  -- Receipt, VAT, and goods evidence attached to debts.
  if exists (
    select 1
    from debts d
    where app_attachment_json_matches(d.nghiem_thu_files, v_bucket, v_path, v_url)
      and app_can_view_debt_evidence(d, p_actor)
  ) then
    return true;
  end if;

  -- Cashier/accounting payment proof on request lines.
  if exists (
    select 1
    from payment_request_lines l
    left join debts d on d.id = l.debt_id
    left join proposals p on p.id = d.proposal_id
    where app_attachment_json_matches(l.proof_files, v_bucket, v_path, v_url)
      and (
        p_actor.role in ('KeToanCongNo', 'ThuQuy')
        or (l.paid = true and p.nguoi_tao = p_actor.id)
      )
  ) then
    return true;
  end if;

  -- Cashier/accounting payment proof duplicated on payment rows.
  if exists (
    select 1
    from payments pm
    left join debts d on d.ma_cn = pm.ma_cn
    left join proposals p on p.id = d.proposal_id
    where app_attachment_json_matches(pm.proof_files, v_bucket, v_path, v_url)
      and (
        p_actor.role in ('KeToanCongNo', 'ThuQuy')
        or p.nguoi_tao = p_actor.id
      )
  ) then
    return true;
  end if;

  -- Direct and group chat attachments.
  if exists (
    select 1
    from messages m
    where app_attachment_json_matches(m.attachments, v_bucket, v_path, v_url)
      and (
        m.from_user = p_actor.id
        or m.to_user = p_actor.id
        or exists (
          select 1
          from chat_group_members gm
          where gm.group_id = m.group_id
            and gm.user_id = p_actor.id
        )
      )
  ) then
    return true;
  end if;

  return false;
end;
$$;

create or replace function rpc_audit_sensitive_file_link(
  p_bucket text,
  p_path text default null,
  p_url text default null,
  p_name text default null,
  p_context text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_bucket text := nullif(trim(coalesce(p_bucket, '')), '');
  v_path text := nullif(trim(coalesce(p_path, '')), '');
  v_url text := nullif(trim(coalesce(p_url, '')), '');
  v_entity_id text;
  v_payload jsonb;
begin
  select * into v_actor from profiles where id = auth.uid();
  if v_actor is null then
    raise exception 'Chưa đăng nhập.';
  end if;
  if v_actor.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;
  if v_bucket is null then
    v_bucket := 'attachments';
  end if;
  if v_path is null and v_url is null then
    raise exception 'Tệp đính kèm thiếu đường dẫn.';
  end if;

  v_entity_id := coalesce(v_bucket || '/' || v_path, 'url:' || md5(v_url));
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'bucket', v_bucket,
    'path', v_path,
    'urlHash', case when v_url is not null then md5(v_url) end,
    'name', nullif(trim(coalesce(p_name, '')), ''),
    'context', nullif(trim(coalesce(p_context, '')), ''),
    'expiresInSeconds', case when v_bucket = 'business-attachments' then 120 else null end
  ));

  if not app_can_access_sensitive_file(v_actor, v_bucket, v_path, v_url) then
    perform write_audit(
      v_actor,
      'SENSITIVE_FILE_LINK_DENIED',
      'storage.objects',
      v_entity_id,
      null,
      v_payload,
      'DENIED',
      'Không có quyền mở tệp đính kèm.'
    );
    raise exception 'Bạn không có quyền mở tệp đính kèm này.';
  end if;

  perform write_audit(
    v_actor,
    'SENSITIVE_FILE_LINK_REQUEST',
    'storage.objects',
    v_entity_id,
    null,
    v_payload,
    'OK',
    'Đã kiểm tra quyền trước khi mở/tạo liên kết tệp.'
  );

  return jsonb_build_object('ok', true, 'bucket', v_bucket, 'path', v_path, 'expiresInSeconds', 120);
end;
$$;

-- Compatibility wrapper for the private attachment slice. The frontend can call
-- this before creating a short-lived signed URL.
create or replace function rpc_check_business_attachment_access(p_path text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return rpc_audit_sensitive_file_link('business-attachments', p_path, null, null, 'business-attachments');
end;
$$;

create or replace function rpc_admin_list_audit_log(
  p_limit int default 100,
  p_action text default null,
  p_entity_type text default null,
  p_from date default null,
  p_to date default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_action text := nullif(trim(coalesce(p_action, '')), '');
  v_entity_type text := nullif(trim(coalesce(p_entity_type, '')), '');
  v_rows jsonb;
begin
  v_actor := require_permission('user:manage');

  select coalesce(jsonb_agg(jsonb_build_object(
      'time', to_char(a."time" at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD HH24:MI:SS'),
      'actor', coalesce(a.actor_name, a.actor_email, a.actor_id::text, ''),
      'email', a.actor_email,
      'role', a.role,
      'action', a.action,
      'entity', a.entity_type,
      'entityId', a.entity_id,
      'result', a.result,
      'message', a.message
    ) order by a."time" desc), '[]'::jsonb)
    into v_rows
  from (
    select *
    from audit_log
    where (v_action is null or action = v_action)
      and (v_entity_type is null or entity_type = v_entity_type)
      and (p_from is null or "time" >= p_from::timestamptz)
      and (p_to is null or "time" < (p_to + 1)::timestamptz)
    order by "time" desc
    limit v_limit
  ) a;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- ---- Draft submit status transition ---------------------------------------
create or replace function rpc_submit_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
  v_after proposals;
  v_dept record;
begin
  v_actor := require_permission('proposal:submit');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if v_p.nguoi_tao is distinct from v_actor.id and v_actor.role <> 'Admin' then
    raise exception 'Bạn chỉ được gửi duyệt đề xuất do mình tạo.';
  end if;
  if v_p.trang_thai <> 'Nháp' then
    raise exception 'Chỉ gửi duyệt được phiếu đang ở trạng thái Nháp.';
  end if;
  select * into v_dept from app_actor_proposal_department(v_actor, '{}'::jsonb);
  if not v_p.trong_ke_hoach_tuan and nullif(trim(coalesce(v_p.giai_trinh_ngoai_ke_hoach,'')),'') is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.';
  end if;
  if v_p.loai_de_xuat = 'MuaHang'
     and (select count(*) from proposal_lines where proposal_id = v_p.id) >= 2
     and coalesce(jsonb_array_length(v_p.attachments), 0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;

  update proposals
  set trang_thai = 'Chờ duyệt',
      ly_do_tra_lai = null,
      bo_phan = coalesce(v_dept.bo_phan, bo_phan),
      department_id = coalesce(v_dept.department_id, department_id)
  where id = v_p.id
  returning * into v_after;

  perform write_audit(
    v_actor,
    'SUBMIT_PROPOSAL',
    'proposals',
    p_ma_de_xuat,
    jsonb_build_object('status', v_p.trang_thai, 'boPhan', v_p.bo_phan),
    jsonb_build_object('status', v_after.trang_thai, 'boPhan', v_after.bo_phan),
    'OK',
    'Gửi duyệt đề xuất.'
  );

  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

-- ---- Explicit department override/catalog auditing ------------------------
create or replace function trg_audit_proposal_department_override() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_actor_department_id uuid;
begin
  select * into v_actor from profiles where id = auth.uid();
  if v_actor is null or v_actor.role <> 'Admin' then
    return new;
  end if;

  if TG_OP = 'UPDATE'
     and new.department_id is not distinct from old.department_id
     and new.bo_phan is not distinct from old.bo_phan then
    return new;
  end if;

  v_actor_department_id := app_profile_department_id(v_actor);
  if new.department_id is not null
     and (v_actor_department_id is null or new.department_id is distinct from v_actor_department_id) then
    perform write_audit(
      v_actor,
      'PROPOSAL_DEPARTMENT_OVERRIDE',
      'proposals',
      new.ma_de_xuat,
      case when TG_OP = 'UPDATE' then jsonb_build_object('boPhan', old.bo_phan, 'departmentId', old.department_id) else null end,
      jsonb_build_object('boPhan', new.bo_phan, 'departmentId', new.department_id, 'operation', TG_OP),
      'OK',
      'Admin gán đề xuất sang bộ phận khác.'
    );
  end if;

  return new;
end;
$$;

drop trigger if exists t_audit_proposal_department_override on proposals;
create trigger t_audit_proposal_department_override
after insert or update of bo_phan, department_id on proposals
for each row execute function trg_audit_proposal_department_override();

create or replace function rpc_add_department(p_ten text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ten text := nullif(trim(coalesce(p_ten,'')),'');
  v_id uuid;
begin
  v_actor := require_permission('user:manage');
  if v_ten is null then raise exception 'Cần nhập tên bộ phận.'; end if;

  insert into departments (ten) values (v_ten)
  on conflict (ten) do nothing
  returning id into v_id;

  if v_id is not null then
    perform write_audit(v_actor, 'CREATE_DEPARTMENT', 'departments', v_id::text, null,
      jsonb_build_object('ten', v_ten), 'OK', '');
  end if;

  return jsonb_build_object('ok', true, 'departments', (select coalesce(jsonb_agg(ten order by ten),'[]'::jsonb) from departments));
end;
$$;

create or replace function rpc_add_proposer(p_ten text, p_bo_phan text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ten text := nullif(trim(coalesce(p_ten,'')),'');
  v_before proposers;
  v_after proposers;
  v_bo_phan text := nullif(trim(coalesce(p_bo_phan,'')),'');
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then raise exception 'Cần nhập tên người đề nghị.'; end if;

  select * into v_before from proposers where ten = v_ten;
  insert into proposers (ten, bo_phan) values (v_ten, v_bo_phan)
  on conflict (ten) do update set bo_phan = excluded.bo_phan
  returning * into v_after;

  if v_before is null then
    perform write_audit(v_actor, 'CREATE_PROPOSER', 'proposers', v_after.id::text, null,
      to_jsonb(v_after), 'OK', '');
  elsif v_before.bo_phan is distinct from v_after.bo_phan then
    perform write_audit(v_actor, 'UPDATE_PROPOSER_DEPARTMENT', 'proposers', v_after.id::text,
      to_jsonb(v_before), to_jsonb(v_after), 'OK', '');
  end if;

  return jsonb_build_object('ok', true, 'proposers', (select coalesce(jsonb_agg(jsonb_build_object('ten',ten,'boPhan',bo_phan) order by ten),'[]'::jsonb) from proposers));
end;
$$;

-- ---- Retention: audit minimum 12 months, default 24 months -----------------
create or replace function prune_old_data(p_keep_days int default 730) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_keep_days int := greatest(coalesce(p_keep_days, 730), 30);
  v_audit_keep_days int := greatest(coalesce(p_keep_days, 730), 365);
  v_cut timestamptz := now() - (greatest(coalesce(p_keep_days, 730), 30) || ' days')::interval;
  v_audit_cut timestamptz := now() - (greatest(coalesce(p_keep_days, 730), 365) || ' days')::interval;
  v_n_notif int;
  v_n_audit int;
  v_n_net int := 0;
begin
  v_actor := require_permission('user:manage');
  delete from notifications where created_at < v_cut and da_doc = true;
  get diagnostics v_n_notif = row_count;

  delete from audit_log where "time" < v_audit_cut;
  get diagnostics v_n_audit = row_count;

  begin
    delete from net._http_response where created < now() - interval '30 days';
    get diagnostics v_n_net = row_count;
  exception when others then
    v_n_net := -1;
  end;

  perform write_audit(v_actor, 'PRUNE_OLD_DATA', 'system', null, null,
    jsonb_build_object(
      'notif', v_n_notif,
      'audit', v_n_audit,
      'net', v_n_net,
      'keepDays', v_keep_days,
      'auditKeepDays', v_audit_keep_days
    ),
    'OK',
    ''
  );

  return jsonb_build_object('ok', true, 'notifDeleted', v_n_notif, 'auditDeleted', v_n_audit, 'netDeleted', v_n_net);
end;
$$;

revoke all on function app_attachment_json_matches(jsonb, text, text, text) from public, anon, authenticated;
revoke all on function app_can_access_sensitive_file(profiles, text, text, text) from public, anon, authenticated;
revoke all on function trg_audit_proposal_department_override() from public, anon, authenticated;

grant execute on function rpc_audit_sensitive_file_link(text, text, text, text, text) to authenticated;
grant execute on function rpc_check_business_attachment_access(text) to authenticated;
grant execute on function rpc_admin_list_audit_log(int, text, text, date, date) to authenticated;
grant execute on function rpc_submit_proposal(text) to authenticated;
grant execute on function rpc_add_department(text) to authenticated;
grant execute on function rpc_add_proposer(text, text) to authenticated;
grant execute on function prune_old_data(int) to authenticated;
