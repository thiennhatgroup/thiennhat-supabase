-- ============================================================================
-- 0038_link_material_supplier.sql  (Đợt A)
--  Nối giao dịch về MÃ (material_id / doi_tuong_id) thay vì khớp theo TÊN, để
--  thống kê/báo cáo chính xác kể cả khi tên gõ khác nhau.
--   * Thêm material_id vào proposal_lines / debts / price_quotes.
--   * Thêm doi_tuong_id vào price_quotes.
--   * Backfill theo normalize_text(tên).
--   * Trigger BEFORE INSERT/UPDATE tự nối id cho bản ghi mới (không phải sửa RPC).
--   * Export proposals/quotes: kèm Mã vật tư + Nhóm hàng (+ Mã NCC cho quotes).
-- ============================================================================

alter table proposal_lines add column if not exists material_id uuid references materials (id);
alter table debts          add column if not exists material_id uuid references materials (id);
alter table price_quotes   add column if not exists material_id uuid references materials (id);
alter table price_quotes   add column if not exists doi_tuong_id uuid references doi_tuong (id);

create index if not exists idx_proposal_lines_material on proposal_lines (material_id);
create index if not exists idx_debts_material          on debts (material_id);
create index if not exists idx_price_quotes_material   on price_quotes (material_id);
create index if not exists idx_price_quotes_doi_tuong  on price_quotes (doi_tuong_id);

-- ---- Backfill (khớp theo tên đã chuẩn hoá) ---------------------------------
update proposal_lines pl set material_id = m.id
  from materials m where pl.material_id is null and normalize_text(m.ten) = normalize_text(pl.mat_hang);

update debts d set material_id = m.id
  from materials m where d.material_id is null and normalize_text(m.ten) = normalize_text(d.mat_hang);

update price_quotes q set material_id = m.id
  from materials m where q.material_id is null and normalize_text(m.ten) = normalize_text(q.mat_hang);

update price_quotes q set doi_tuong_id = dt.id
  from doi_tuong dt where q.doi_tuong_id is null and normalize_text(dt.ten_doi_tuong) = normalize_text(q.ncc);

-- ---- Trigger tự nối cho bản ghi mới ----------------------------------------
create or replace function trg_link_material_by_name() returns trigger
language plpgsql as $$
begin
  if new.material_id is null and new.mat_hang is not null then
    new.material_id := (select id from materials where normalize_text(ten) = normalize_text(new.mat_hang) limit 1);
  end if;
  return new;
end; $$;

create or replace function trg_link_quote_by_name() returns trigger
language plpgsql as $$
begin
  if new.material_id is null and new.mat_hang is not null then
    new.material_id := (select id from materials where normalize_text(ten) = normalize_text(new.mat_hang) limit 1);
  end if;
  if new.doi_tuong_id is null and new.ncc is not null then
    new.doi_tuong_id := (select id from doi_tuong where normalize_text(ten_doi_tuong) = normalize_text(new.ncc) limit 1);
  end if;
  return new;
end; $$;

drop trigger if exists t_link_material_proposal_lines on proposal_lines;
create trigger t_link_material_proposal_lines before insert or update of mat_hang, material_id on proposal_lines
  for each row execute function trg_link_material_by_name();

drop trigger if exists t_link_material_debts on debts;
create trigger t_link_material_debts before insert or update of mat_hang, material_id on debts
  for each row execute function trg_link_material_by_name();

drop trigger if exists t_link_quote on price_quotes;
create trigger t_link_quote before insert or update of mat_hang, ncc, material_id, doi_tuong_id on price_quotes
  for each row execute function trg_link_quote_by_name();

-- ---- Export: kèm Mã vật tư / Nhóm hàng / Mã NCC ----------------------------
create or replace function rpc_export_proposals(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('recent:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày đề xuất', r->>'Mã đề xuất'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Mã đề xuất', p.ma_de_xuat,
      'Loại', case when p.loai_de_xuat='TamUng' then 'Tạm ứng' else 'Mua hàng' end,
      'Ngày đề xuất', to_char(p.ngay_de_xuat,'YYYY-MM-DD'),
      'Người đề nghị', p.nguoi_de_nghi,
      'Bộ phận', p.bo_phan,
      'Mã NCC', dt.ma_doi_tuong,
      'Nhà cung cấp', p.ten_doi_tuong,
      'Trong kế hoạch tuần', case when p.trong_ke_hoach_tuan then 'Có' else 'Không' end,
      'Mã vật tư', m.ma_vat_tu,
      'Nhóm hàng', m.nhom,
      'Mặt hàng', l.mat_hang,
      'SL đặt', l.sl_dat,
      'Đơn giá', l.don_gia_chua_vat,
      'VAT', l.vat_rate,
      'Thành tiền sau VAT', l.thanh_tien_sau_vat,
      'Trạng thái duyệt', p.trang_thai,
      'Ngày duyệt', to_char(p.approved_at,'YYYY-MM-DD'),
      'SL nghiệm thu', (select d.sl_thuc_nhan from debts d where d.proposal_id=p.id and d.mat_hang=l.mat_hang order by d.created_at limit 1),
      'Đã nghiệm thu', case when exists (select 1 from debts d where d.proposal_id=p.id and d.mat_hang=l.mat_hang and d.sl_thuc_nhan is not null) then 'Có' else 'Chưa' end
    ) as r
    from proposals p
    join proposal_lines l on l.proposal_id = p.id
    left join materials m on m.id = l.material_id
    left join doi_tuong dt on dt.id = p.doi_tuong_id
    where (p_from is null or p.ngay_de_xuat >= p_from) and (p_to is null or p.ngay_de_xuat <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_export_quotes(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('recent:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Ngày', to_char(q.ngay,'YYYY-MM-DD'),
      'Mã vật tư', m.ma_vat_tu,
      'Nhóm hàng', m.nhom,
      'Mặt hàng', q.mat_hang,
      'Mã NCC', dt.ma_doi_tuong,
      'Nhà cung cấp', q.ncc,
      'ĐVT', q.dvt,
      'Giá gọi', q.gia,
      'VAT', q.vat_status,
      'Đề xuất', q.de_xuat,
      'Ghi chú', q.ghi_chu,
      'Nguồn', q.nguon
    ) as r
    from price_quotes q
    left join materials m on m.id = q.material_id
    left join doi_tuong dt on dt.id = q.doi_tuong_id
    where (p_from is null or q.ngay >= p_from) and (p_to is null or q.ngay <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

grant execute on function rpc_export_proposals(date, date) to authenticated;
grant execute on function rpc_export_quotes(date, date) to authenticated;
