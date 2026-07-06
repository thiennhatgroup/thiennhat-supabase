-- ============================================================================
-- 0069_upload_limits_file_type_guardrails.sql
--  Add upload guardrails for business attachments:
--    * max 5 MB per file
--    * max 20 MB per persisted upload batch
--    * PDF and common image formats only
--    * private Storage bucket access when Supabase allows configuring it in SQL
-- ============================================================================

create or replace function app_upload_allowed_extensions()
returns text[]
language sql immutable as $$
  select array['pdf','jpg','jpeg','png','webp','gif','heic','heif']::text[];
$$;

create or replace function app_upload_allowed_mime_types()
returns text[]
language sql immutable as $$
  select array[
    'application/pdf',
    'application/x-pdf',
    'image/jpeg',
    'image/jpg',
    'image/pjpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/heic',
    'image/heif'
  ]::text[];
$$;

create or replace function app_upload_file_extension(p_name text)
returns text
language sql immutable as $$
  select lower(coalesce(substring(coalesce(p_name, '') from '\.([A-Za-z0-9]+)$'), ''));
$$;

create or replace function app_validate_upload_attachments(p_files jsonb, p_context text default 'file')
returns void
language plpgsql stable as $$
declare
  v_file jsonb;
  v_idx int := 0;
  v_name text;
  v_bucket text;
  v_path text;
  v_ext text;
  v_type text;
  v_size_text text;
  v_size bigint;
  v_total bigint := 0;
  v_prefixes text[];
  v_label text;
begin
  if p_files is null then
    return;
  end if;

  if jsonb_typeof(p_files) <> 'array' then
    raise exception 'Danh sách tệp không hợp lệ.';
  end if;

  v_prefixes := case coalesce(p_context, 'file')
    when 'proposal' then array['bao-gia/']
    when 'receipt' then array['nghiem-thu/']
    when 'payment' then array['chi-tien/']
    when 'chat' then array['chat/']
    else array['']
  end;

  v_label := case coalesce(p_context, 'file')
    when 'proposal' then 'Báo giá'
    when 'receipt' then 'Chứng từ nghiệm thu/VAT'
    when 'payment' then 'Chứng từ chi tiền'
    else 'Tệp đính kèm'
  end;

  for v_file in select value from jsonb_array_elements(p_files) as t(value) loop
    v_idx := v_idx + 1;

    if jsonb_typeof(v_file) <> 'object' then
      raise exception '% #% không hợp lệ.', v_label, v_idx;
    end if;

    v_name := nullif(trim(coalesce(v_file->>'name', '')), '');
    v_bucket := coalesce(nullif(trim(coalesce(v_file->>'bucket', '')), ''), 'attachments');
    v_path := nullif(trim(coalesce(v_file->>'path', '')), '');
    v_ext := app_upload_file_extension(v_name);
    v_type := lower(nullif(trim(coalesce(v_file->>'type', '')), ''));
    v_size_text := trim(coalesce(v_file->>'size', ''));

    if v_name is null or v_path is null then
      raise exception '% #% thiếu tên tệp hoặc đường dẫn lưu trữ.', v_label, v_idx;
    end if;

    if v_bucket <> 'attachments' then
      raise exception 'Tệp "%" phải nằm trong kho lưu trữ attachments của hệ thống.', v_name;
    end if;

    if not exists (select 1 from unnest(v_prefixes) as p(prefix) where v_path like p.prefix || '%') then
      raise exception 'Tệp "%" không nằm đúng thư mục lưu trữ cho nghiệp vụ này.', v_name;
    end if;

    if not (v_ext = any(app_upload_allowed_extensions())) then
      raise exception 'Tệp "%" không đúng định dạng. Chỉ nhận PDF hoặc ảnh JPG, PNG, WebP, GIF, HEIC.', v_name;
    end if;

    if v_type is not null and not (v_type = any(app_upload_allowed_mime_types())) then
      raise exception 'Tệp "%" không đúng loại nội dung. Chỉ nhận PDF hoặc ảnh thông dụng.', v_name;
    end if;

    if v_size_text !~ '^[0-9]+$' then
      raise exception 'Tệp "%" thiếu thông tin dung lượng.', v_name;
    end if;

    v_size := v_size_text::bigint;
    if v_size <= 0 or v_size > 5 * 1024 * 1024 then
      raise exception 'Tệp "%" vượt giới hạn 5 MB/tệp.', v_name;
    end if;

    v_total := v_total + v_size;
    if v_total > 20 * 1024 * 1024 then
      raise exception 'Tổng dung lượng tệp vượt giới hạn 20 MB cho một lần tải.';
    end if;
  end loop;
end;
$$;

create or replace function trg_upload_guard_proposals()
returns trigger
language plpgsql as $$
declare
  v_should_check boolean;
begin
  if tg_op = 'INSERT' then
    v_should_check := true;
  else
    v_should_check := new.attachments is distinct from old.attachments
      or new.loai_de_xuat is distinct from old.loai_de_xuat;
  end if;

  if v_should_check then
    perform app_validate_upload_attachments(coalesce(new.attachments, '[]'::jsonb), 'proposal');

    if new.loai_de_xuat = 'MuaHang'
       and jsonb_array_length(coalesce(new.attachments, '[]'::jsonb)) = 0 then
      raise exception 'Đề xuất mua hàng cần đính kèm báo giá PDF/ảnh.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists t_upload_guard_proposals on proposals;
create trigger t_upload_guard_proposals
before insert or update of attachments, loai_de_xuat on proposals
for each row execute function trg_upload_guard_proposals();

create or replace function trg_upload_guard_debt_evidence()
returns trigger
language plpgsql as $$
declare
  v_should_check boolean;
begin
  if tg_op = 'INSERT' then
    v_should_check := true;
  else
    v_should_check := new.nghiem_thu_files is distinct from old.nghiem_thu_files
      or (old.sl_thuc_nhan is null and new.sl_thuc_nhan is not null);
  end if;

  if v_should_check then
    perform app_validate_upload_attachments(coalesce(new.nghiem_thu_files, '[]'::jsonb), 'receipt');

    if new.sl_thuc_nhan is not null
       and jsonb_array_length(coalesce(new.nghiem_thu_files, '[]'::jsonb)) = 0 then
      raise exception 'Nghiệm thu cần đính kèm hóa đơn VAT và BBGN/phiếu cân/ảnh.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists t_upload_guard_debt_evidence on debts;
create trigger t_upload_guard_debt_evidence
before insert or update of nghiem_thu_files, sl_thuc_nhan on debts
for each row execute function trg_upload_guard_debt_evidence();

create or replace function trg_upload_guard_payment_request_line_proof()
returns trigger
language plpgsql as $$
declare
  v_should_check boolean;
begin
  if tg_op = 'INSERT' then
    v_should_check := true;
  else
    v_should_check := new.proof_files is distinct from old.proof_files
      or new.paid is distinct from old.paid;
  end if;

  if v_should_check then
    perform app_validate_upload_attachments(coalesce(new.proof_files, '[]'::jsonb), 'payment');

    if new.paid
       and jsonb_array_length(coalesce(new.proof_files, '[]'::jsonb)) = 0 then
      raise exception 'Xác nhận chi tiền cần đính kèm phiếu chi hoặc ảnh ủy nhiệm chi.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists t_upload_guard_payment_request_line_proof on payment_request_lines;
create trigger t_upload_guard_payment_request_line_proof
before insert or update of proof_files, paid on payment_request_lines
for each row execute function trg_upload_guard_payment_request_line_proof();

create or replace function trg_upload_guard_payment_proof()
returns trigger
language plpgsql as $$
declare
  v_should_check boolean;
  v_payment_request_proof boolean;
begin
  if tg_op = 'INSERT' then
    v_should_check := true;
  else
    v_should_check := new.proof_files is distinct from old.proof_files;
  end if;

  v_payment_request_proof := coalesce(new.ghi_chu, '') like 'Chi theo ĐXTT %'
    or coalesce(new.ghi_chu, '') like 'Chi % theo ĐXTT %';

  if v_should_check or v_payment_request_proof then
    perform app_validate_upload_attachments(coalesce(new.proof_files, '[]'::jsonb), 'payment');

    if v_payment_request_proof
       and jsonb_array_length(coalesce(new.proof_files, '[]'::jsonb)) = 0 then
      raise exception 'Chi tiền theo đề xuất thanh toán cần đính kèm phiếu chi hoặc ảnh ủy nhiệm chi.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists t_upload_guard_payment_proof on payments;
create trigger t_upload_guard_payment_proof
before insert or update of proof_files on payments
for each row execute function trg_upload_guard_payment_proof();

-- Configure Supabase Storage when migrations have permission to touch storage.*.
-- The app still validates in the browser and through the triggers above if these
-- dashboard-level bucket settings cannot be changed by SQL in a given project.
do $$
declare
  v_insert_policy_ready boolean := false;
  v_select_policy_ready boolean := false;
begin
  begin
    insert into storage.buckets (id, name, public)
    values ('attachments', 'attachments', false)
    on conflict (id) do update set public = false;
  exception when others then
    raise notice 'skip attachments bucket privacy update: %', sqlerrm;
  end;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'storage' and table_name = 'buckets' and column_name = 'file_size_limit'
  ) then
    begin
      execute $q$update storage.buckets set file_size_limit = 5242880 where id = 'attachments'$q$;
    exception when others then
      raise notice 'skip attachments bucket file_size_limit update: %', sqlerrm;
    end;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'storage' and table_name = 'buckets' and column_name = 'allowed_mime_types'
  ) then
    begin
      execute $q$
        update storage.buckets
           set allowed_mime_types = array[
             'application/pdf',
             'application/x-pdf',
             'image/jpeg',
             'image/jpg',
             'image/pjpeg',
             'image/png',
             'image/webp',
             'image/gif',
             'image/heic',
             'image/heif'
           ]::text[]
         where id = 'attachments'
      $q$;
    exception when others then
      raise notice 'skip attachments bucket allowed_mime_types update: %', sqlerrm;
    end;
  end if;

  begin
    execute 'drop policy if exists "att_insert_guarded" on storage.objects';
    execute $q$
      create policy "att_insert_guarded" on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'attachments'
        and (
          name like 'bao-gia/%'
          or name like 'nghiem-thu/%'
          or name like 'chi-tien/%'
          or name like 'chat/%'
        )
        and lower(coalesce(storage.extension(name), '')) = any (array['pdf','jpg','jpeg','png','webp','gif','heic','heif'])
        and (
          metadata is null
          or metadata->>'size' is null
          or ((metadata->>'size') ~ '^[0-9]+$' and (metadata->>'size')::bigint <= 5242880)
        )
        and (
          metadata is null
          or nullif(lower(metadata->>'mimetype'), '') is null
          or lower(metadata->>'mimetype') = any (array[
            'application/pdf',
            'application/x-pdf',
            'image/jpeg',
            'image/jpg',
            'image/pjpeg',
            'image/png',
            'image/webp',
            'image/gif',
            'image/heic',
            'image/heif'
          ])
        )
      )
    $q$;
    v_insert_policy_ready := true;
  exception when others then
    raise notice 'skip guarded attachments insert policy: %', sqlerrm;
  end;

  if v_insert_policy_ready then
    begin
      execute 'drop policy if exists "att_insert" on storage.objects';
      execute 'alter policy "att_insert_guarded" on storage.objects rename to "att_insert"';
    exception when others then
      raise notice 'skip replacing legacy attachments insert policy: %', sqlerrm;
    end;
  end if;

  begin
    execute 'drop policy if exists "att_select_authenticated" on storage.objects';
    execute $q$
      create policy "att_select_authenticated" on storage.objects
      for select to authenticated
      using (bucket_id = 'attachments')
    $q$;
    v_select_policy_ready := true;
  exception when others then
    raise notice 'skip authenticated attachments select policy: %', sqlerrm;
  end;

  if v_select_policy_ready then
    begin
      execute 'drop policy if exists "att_select" on storage.objects';
      execute 'alter policy "att_select_authenticated" on storage.objects rename to "att_select"';
    exception when others then
      raise notice 'skip replacing legacy attachments select policy: %', sqlerrm;
    end;
  end if;
end $$;

revoke all on function app_upload_allowed_extensions() from public, anon, authenticated;
revoke all on function app_upload_allowed_mime_types() from public, anon, authenticated;
revoke all on function app_upload_file_extension(text) from public, anon, authenticated;
revoke all on function app_validate_upload_attachments(jsonb, text) from public, anon, authenticated;
revoke all on function trg_upload_guard_proposals() from public, anon, authenticated;
revoke all on function trg_upload_guard_debt_evidence() from public, anon, authenticated;
revoke all on function trg_upload_guard_payment_request_line_proof() from public, anon, authenticated;
revoke all on function trg_upload_guard_payment_proof() from public, anon, authenticated;
