-- ============================================================================
-- 0028_attachments_fields.sql
--   * proposals: hạn thanh toán, tồn kho hiện tại, ghi chú cho lãnh đạo,
--     và attachments (báo giá gốc: doc/pdf/ảnh) — jsonb [{name,url}].
--   * debts: nghiem_thu_files (biên bản giao nhận, phiếu cân) — jsonb.
--   * Storage bucket 'attachments' (public) + policy cho phép authenticated
--     upload và mọi người đọc. Bọc trong DO/exception để nếu Supabase chặn
--     quyền schema storage thì migration vẫn chạy tiếp (tạo bucket tay ở
--     Dashboard là được).
-- ============================================================================

alter table proposals add column if not exists han_thanh_toan date;
alter table proposals add column if not exists ton_kho numeric;
alter table proposals add column if not exists note_lanh_dao text;
alter table proposals add column if not exists attachments jsonb not null default '[]'::jsonb;

alter table debts add column if not exists nghiem_thu_files jsonb not null default '[]'::jsonb;

do $$
begin
  begin
    insert into storage.buckets (id, name, public) values ('attachments', 'attachments', true)
    on conflict (id) do nothing;
  exception when others then raise notice 'skip bucket: %', sqlerrm; end;
  begin execute $q$create policy "att_insert" on storage.objects for insert to authenticated with check (bucket_id = 'attachments')$q$;
  exception when others then null; end;
  begin execute $q$create policy "att_select" on storage.objects for select using (bucket_id = 'attachments')$q$;
  exception when others then null; end;
end $$;
