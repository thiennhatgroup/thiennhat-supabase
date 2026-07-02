-- ============================================================================
-- 0044_quote_vat_rate.sql
--  Báo giá NCC dùng %VAT CỤ THỂ theo từng dòng (0/8/10%...) thay cho ước lượng
--  VAT toàn cục. Thêm cột price_quotes.vat_rate; dashboard tính giá sau VAT theo
--  rate của dòng (fallback default_vat_rate cho dữ liệu cũ). rpc_add_price_quote
--  nhận p_vat_rate và lưu 'Chưa VAT' + rate.
-- ============================================================================

alter table price_quotes add column if not exists vat_rate numeric;

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
      case when pq.vat_status = 'Đã gồm VAT' then pq.gia else round(pq.gia * (1 + coalesce(pq.vat_rate, v_vat)), 2) end as gia_sau_vat,
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
      'vatStatus', vat_status, 'vatRate', vat_rate,
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
      case when pq.vat_status = 'Đã gồm VAT' then pq.gia else round(pq.gia * (1 + coalesce(pq.vat_rate, v_vat)), 2) end as gia_sau_vat,
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
      case when pq.vat_status = 'Đã gồm VAT' then pq.gia else round(pq.gia * (1 + coalesce(pq.vat_rate, v_vat)), 2) end as gia_sau_vat,
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

drop function if exists rpc_add_price_quote(date, text, text, numeric, text, text, text, text);
create or replace function rpc_add_price_quote(
  p_ngay date,
  p_mat_hang text,
  p_ncc text,
  p_gia numeric,
  p_vat_status text default 'Chưa VAT',
  p_dvt text default null,
  p_vat_rate numeric default null,
  p_de_xuat text default 'Không',
  p_ghi_chu text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_row price_quotes; v_status text;
begin
  v_actor := require_permission('quote:sync');
  if p_mat_hang is null or trim(p_mat_hang) = '' then raise exception 'Thiếu Mặt hàng.'; end if;
  if p_ncc is null or trim(p_ncc) = '' then raise exception 'Thiếu Nhà cung cấp.'; end if;
  if p_gia is null or p_gia < 0 then raise exception 'Thiếu Giá gọi hoặc giá không hợp lệ.'; end if;
  -- Nếu có %VAT cụ thể -> giá nhập là GIÁ CHƯA VAT, dashboard tự cộng theo rate.
  v_status := case when p_vat_rate is not null then 'Chưa VAT' else coalesce(p_vat_status, 'Chưa VAT') end;
  perform ensure_material(p_mat_hang, p_dvt);
  insert into price_quotes (ngay, mat_hang, ncc, gia, vat_status, vat_rate, dvt, de_xuat, ghi_chu, nguon, created_by)
  values (coalesce(p_ngay, current_date), trim(p_mat_hang), trim(p_ncc), p_gia,
          v_status, p_vat_rate, p_dvt, coalesce(p_de_xuat, 'Không'), p_ghi_chu, 'WebApp', v_actor.id)
  returning * into v_row;
  perform write_audit(v_actor, 'ADD_PRICE_QUOTE', 'price_quotes', v_row.id::text, null, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'id', v_row.id);
end;
$$;

grant execute on function rpc_get_quote_dashboard(text, date, int) to authenticated;
grant execute on function rpc_add_price_quote(date, text, text, numeric, text, text, numeric, text, text) to authenticated;
