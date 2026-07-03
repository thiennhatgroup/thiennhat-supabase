-- ============================================================================
-- 0050_quote_multi_covat.sql  (Đợt B2)
--  * price_quotes.co_vat: NCC có xuất hóa đơn VAT hay không (mặc định có).
--    Nếu KHÔNG xuất VAT -> giá sau VAT = giá (không cộng VAT khi so sánh).
--  * rpc_add_price_quotes_batch: nhập NHIỀU mặt hàng cho CÙNG 1 NCC một lần.
-- ============================================================================

alter table price_quotes add column if not exists co_vat boolean not null default true;

create or replace function rpc_get_quote_dashboard(
  p_item text default null,
  p_as_of date default null,
  p_limit int default 30
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_vat numeric;
  v_as_of date;
  v_item text := nullif(trim(coalesce(p_item, '')), '');
  v_limit int := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_rows jsonb;
  v_history jsonb;
  v_best jsonb;
  v_count int;
begin
  perform require_permission('quote:read');

  select coalesce((value #>> '{}')::numeric, 0.08) into v_vat from app_config where key = 'default_vat_rate';
  v_vat := coalesce(v_vat, 0.08);

  v_as_of := p_as_of;
  if v_as_of is null then
    select max(ngay) into v_as_of from price_quotes
    where v_item is null or normalize_text(mat_hang) = normalize_text(v_item);
  end if;
  if v_as_of is null then
    v_as_of := current_date;
  end if;

  -- Every quote row up to (and including) the comparison date, for the chosen item.
  with base as (
    select
      pq.*,
      case when pq.vat_status = 'Đã gồm VAT' then pq.gia when pq.co_vat = false then pq.gia else round(pq.gia * (1 + coalesce(pq.vat_rate, v_vat)), 2) end as gia_sau_vat,
      case when pq.vat_status = 'Đã gồm VAT' then round(pq.gia / (1 + coalesce(pq.vat_rate, v_vat)), 2) else pq.gia end as gia_truoc_vat
    from price_quotes pq
    where (v_item is null or normalize_text(pq.mat_hang) = normalize_text(v_item))
      and pq.ngay <= v_as_of
  ),
  -- Latest quote per supplier (mirrors latestPriceRowsBySupplierAsOf_ when an item is given).
  ranked as (
    select b.*, row_number() over (
      partition by normalize_text(b.ncc)
      order by b.ngay desc, b.created_at desc
    ) as rn
    from base b
  ),
  latest as (
    select * from ranked where rn = 1
  ),
  -- Previous quote (any date strictly before this one) for the same item+supplier, for delta/trend.
  with_prev as (
    select
      l.*,
      prev.gia_sau_vat as prev_price
    from latest l
    left join lateral (
      select b2.gia_sau_vat
      from base b2
      where normalize_text(b2.ncc) = normalize_text(l.ncc)
        and b2.ngay < l.ngay
      order by b2.ngay desc, b2.created_at desc
      limit 1
    ) prev on true
  ),
  ordered as (
    select *, row_number() over (order by gia_sau_vat asc, ncc asc) as rk
    from with_prev
  ),
  top_n as (
    select * from ordered where rk <= v_limit
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'rank', rk,
      'supplier', ncc,
      'date', to_char(ngay, 'DD/MM/YYYY'),
      'priceBeforeVat', gia_truoc_vat,
      'vatStatus', vat_status, 'vatRate', vat_rate, 'coVat', co_vat,
      'priceAfterVat', gia_sau_vat,
      'delta', case when prev_price is not null then round(gia_sau_vat - prev_price, 2) end,
      'pct', case when prev_price is not null and prev_price <> 0 then round((gia_sau_vat - prev_price) / prev_price, 4) end,
      'trend', case
        when prev_price is null then 'Giá đầu tiên'
        when gia_sau_vat > prev_price then 'Tăng'
        when gia_sau_vat < prev_price then 'Giảm'
        else 'Không đổi' end,
      'unit', dvt,
      'proposal', de_xuat,
      'note', ghi_chu,
      'recommended', case when rk = 1 then 'Giá tốt nhất' else 'So sánh' end
    ) order by rk), '[]'::jsonb),
    count(*)
  into v_rows, v_count
  from top_n;

  with base as (
    select
      pq.*,
      case when pq.vat_status = 'Đã gồm VAT' then pq.gia when pq.co_vat = false then pq.gia else round(pq.gia * (1 + coalesce(pq.vat_rate, v_vat)), 2) end as gia_sau_vat,
      case when pq.vat_status = 'Đã gồm VAT' then round(pq.gia / (1 + coalesce(pq.vat_rate, v_vat)), 2) else pq.gia end as gia_truoc_vat
    from price_quotes pq
    where (v_item is null or normalize_text(pq.mat_hang) = normalize_text(v_item))
      and pq.ngay <= v_as_of
  )
  select jsonb_agg(x order by ngay desc) into v_history
  from (
    select
      to_char(b.ngay, 'DD/MM/YYYY') as ngay_disp,
      b.ngay,
      b.ncc as supplier,
      b.gia_sau_vat as "priceAfterVat",
      b.gia_truoc_vat as "priceBeforeVat",
      b.vat_status as "vatStatus",
      b.dvt as unit,
      b.ghi_chu as note,
      (
        select b2.gia_sau_vat from base b2
        where normalize_text(b2.ncc) = normalize_text(b.ncc) and b2.ngay < b.ngay
        order by b2.ngay desc, b2.created_at desc limit 1
      ) as prev_price
    from base b
    order by b.ngay desc, b.created_at desc
    limit 25
  ) x;

  with base as (
    select
      pq.*,
      case when pq.vat_status = 'Đã gồm VAT' then pq.gia when pq.co_vat = false then pq.gia else round(pq.gia * (1 + coalesce(pq.vat_rate, v_vat)), 2) end as gia_sau_vat,
      case when pq.vat_status = 'Đã gồm VAT' then round(pq.gia / (1 + coalesce(pq.vat_rate, v_vat)), 2) else pq.gia end as gia_truoc_vat
    from price_quotes pq
    where (v_item is null or normalize_text(pq.mat_hang) = normalize_text(v_item))
      and pq.ngay <= v_as_of
  ),
  ranked as (
    select b.*, row_number() over (
      partition by normalize_text(b.ncc)
      order by b.ngay desc, b.created_at desc
    ) as rn
    from base b
  ),
  latest as (
    select * from ranked where rn = 1
  )
  select jsonb_build_object(
    'supplier', ncc, 'priceAfterVat', gia_sau_vat, 'unit', dvt,
    'date', to_char(ngay, 'DD/MM/YYYY')
  ) into v_best
  from latest
  order by gia_sau_vat asc, ncc asc
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'item', coalesce(v_item, ''),
    'asOf', to_char(v_as_of, 'DD/MM/YYYY'),
    'supplierCount', v_count,
    'best', v_best,
    'rows', v_rows,
    'history', coalesce(v_history, '[]'::jsonb),
    'message', 'Đã tải dashboard báo giá.'
  );
end;
$$;

-- Nhập nhiều dòng báo giá cho cùng 1 NCC. p_lines: [{matHang,gia,dvt,vatRate,coVat,ghiChu,deXuat}]
create or replace function rpc_add_price_quotes_batch(p_ncc text, p_ngay date, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ncc text := nullif(trim(coalesce(p_ncc,'')),''); v_line jsonb; v_gia numeric; v_mat text; v_n int := 0;
begin
  v_actor := require_permission('quote:sync');
  if v_ncc is null then raise exception 'Thiếu Nhà cung cấp.'; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then raise exception 'Cần ít nhất một dòng mặt hàng.'; end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_mat := nullif(trim(coalesce(v_line->>'matHang','')),'');
    v_gia := parse_number(v_line->>'gia');
    if v_mat is null or v_gia is null or v_gia < 0 then continue; end if;
    perform ensure_material(v_mat, nullif(trim(coalesce(v_line->>'dvt','')),''));
    insert into price_quotes (ngay, mat_hang, ncc, gia, vat_status, vat_rate, co_vat, dvt, de_xuat, ghi_chu, nguon, created_by)
    values (coalesce(p_ngay, current_date), v_mat, v_ncc, v_gia, 'Chưa VAT',
            coalesce(parse_number(v_line->>'vatRate'), 0.08),
            coalesce((v_line->>'coVat')::boolean, true),
            nullif(trim(coalesce(v_line->>'dvt','')),''),
            coalesce(nullif(trim(coalesce(v_line->>'deXuat','')),''), 'Không'),
            v_line->>'ghiChu', 'WebApp', v_actor.id);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Không có dòng hợp lệ (cần mặt hàng + giá).'; end if;
  perform write_audit(v_actor, 'ADD_PRICE_QUOTES', 'price_quotes', v_ncc, null, jsonb_build_object('ncc', v_ncc, 'lines', v_n), 'OK', '');
  return jsonb_build_object('ok', true, 'lines', v_n);
end; $$;

grant execute on function rpc_get_quote_dashboard(text, date, int) to authenticated;
grant execute on function rpc_add_price_quotes_batch(text, date, jsonb) to authenticated;
