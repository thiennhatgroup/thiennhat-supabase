-- ============================================================================
-- 0009_rpc_dashboard_settlement.sql
-- rpc_get_debt_dashboard()   mirrors apiGetDebtDashboard()
-- rpc_preview_settlement()   mirrors apiPreviewSettlement() / buildWebSettlementPlan_() [read-only]
-- rpc_confirm_settlement()   mirrors apiConfirmSettlement()  [performs the writes]
--
-- Settlement algorithm (per doi_tuong group), identical to
-- luuVaClearKhoanDaTatToan_() / buildWebSettlementPlan_():
--   1. remaining_paid := sum(da_thanh_toan) of every open row in the group.
--   2. Obligations = rows with actual receipt qty and thanh_tien_thuc_nhan>0,
--      processed oldest-due-first. Each one is paid out of remaining_paid;
--      if fully covered (balance<1) it is archived, otherwise it stays open
--      with its partial allocation.
--   3. Any row that was NOT an obligation (still awaiting receipt qty,
--      previous advances, etc.) gets its paid amount re-derived from
--      whatever remains in the pool, capped at what it already had — this
--      is what stops a settlement run from double-counting money.
--   4. Whatever is still left over becomes a fresh "Tạm ứng/trả trước chưa
--      đối trừ" row, exactly like the AR-TAMUNG row the sheet version wrote.
-- ============================================================================

create or replace function rpc_get_debt_dashboard(p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := (p_filter->>'fromDate')::date;
  v_to date := (p_filter->>'toDate')::date;
  v_ma text := nullif(trim(coalesce(p_filter->>'maDoiTuong', '')), '');
  v_status text := nullif(trim(coalesce(p_filter->>'status', '')), '');
  v_summary jsonb;
  v_totals jsonb;
begin
  perform require_permission('dashboard:read');

  with rows as (
    select vd.*, dt.ma_doi_tuong
    from v_debts vd
    join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false
      and (vd.thanh_tien_thuc_nhan <> 0 or vd.da_thanh_toan <> 0)
      and (v_ma is null or dt.ma_doi_tuong = v_ma)
      and (v_status is null or vd.trang_thai_dong ilike '%' || v_status || '%')
      and (
        (v_from is null and v_to is null) or (
          coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) is not null
          and (v_from is null or coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) >= v_from)
          and (v_to is null or coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) <= v_to)
        )
      )
  ),
  grouped as (
    select
      ma_doi_tuong,
      max(ten_doi_tuong) as ten_doi_tuong,
      sum(thanh_tien_thuc_nhan) as actual,
      sum(da_thanh_toan) as paid,
      count(*) as cnt
    from rows
    group by ma_doi_tuong
  ),
  computed as (
    select
      ma_doi_tuong, ten_doi_tuong, round(actual, 2) as actual, round(paid, 2) as paid,
      round(actual - paid, 2) as net,
      greatest(round(actual - paid, 2), 0) as ap,
      greatest(round(paid - actual, 2), 0) as ar,
      cnt
    from grouped
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'maDoiTuong', ma_doi_tuong, 'tenDoiTuong', ten_doi_tuong, 'actual', actual, 'paid', paid,
      'net', net, 'ap', ap, 'ar', ar, 'count', cnt,
      'status', case when ap > 1 then 'AP còn phải trả' when ar > 1 then 'AR/tạm ứng ròng' else 'Đã cân bằng' end
    ) order by abs(net) desc), '[]'::jsonb),
    jsonb_build_object(
      'actual', coalesce(sum(actual), 0), 'paid', coalesce(sum(paid), 0), 'net', coalesce(sum(net), 0),
      'ap', coalesce(sum(ap), 0), 'ar', coalesce(sum(ar), 0), 'count', coalesce(sum(cnt), 0)
    )
  into v_summary, v_totals
  from computed;

  return jsonb_build_object('ok', true, 'totals', v_totals, 'summary', v_summary);
end;
$$;

-- Shared core, parameterised by `p_write` so preview and confirm run the
-- exact same algorithm; only rpc_confirm_settlement passes true.
create or replace function settlement_run_(p_actor profiles, p_ma_doi_tuong text, p_write boolean) returns jsonb
language plpgsql as $$
declare
  v_group record;
  v_row record;
  v_remaining numeric;
  v_gap numeric;
  v_allocated numeric;
  v_preview jsonb := '[]'::jsonb;
  v_archived_count int := 0;
  v_kept_count int := 0;
  v_now date := current_date;
begin
  for v_group in
    select dt.id, dt.ma_doi_tuong, dt.ten_doi_tuong
    from doi_tuong dt
    where exists (select 1 from debts d where d.doi_tuong_id = dt.id and d.is_archived = false)
      and (p_ma_doi_tuong is null or dt.ma_doi_tuong = p_ma_doi_tuong)
  loop
    select coalesce(sum(da_thanh_toan), 0) into v_remaining from debts where doi_tuong_id = v_group.id and is_archived = false;

    -- Obligations first, oldest-due-first (compareCongNoItemsForSettlement_).
    for v_row in
      select d.*, vd.thanh_tien_thuc_nhan, vd.can_settle
      from debts d join v_debts vd on vd.id = d.id
      where d.doi_tuong_id = v_group.id and d.is_archived = false and vd.can_settle and vd.thanh_tien_thuc_nhan > 0
      order by coalesce(d.han_thanh_toan, d.ngay_nhan, d.ngay_duyet, d.ngay_de_xuat) asc nulls last, d.created_at asc
    loop
      v_allocated := round(least(v_remaining, v_row.thanh_tien_thuc_nhan), 2);
      v_remaining := round(greatest(v_remaining - v_allocated, 0), 2);
      v_gap := round(v_row.thanh_tien_thuc_nhan - v_allocated, 2);
      if v_gap < 1 then
        v_preview := v_preview || jsonb_build_array(jsonb_build_object('action', 'archive', 'maCN', v_row.ma_cn, 'doiTuong', v_group.ten_doi_tuong, 'actual', v_row.thanh_tien_thuc_nhan, 'allocated', v_allocated));
        v_archived_count := v_archived_count + 1;
        if p_write then
          update debts set da_thanh_toan = v_row.thanh_tien_thuc_nhan, is_archived = true, archived_at = now(), archived_by = p_actor.id where id = v_row.id;
        end if;
      else
        v_preview := v_preview || jsonb_build_array(jsonb_build_object('action', 'keep', 'maCN', v_row.ma_cn, 'doiTuong', v_group.ten_doi_tuong, 'actual', v_row.thanh_tien_thuc_nhan, 'allocated', v_allocated));
        v_kept_count := v_kept_count + 1;
        if p_write then
          update debts set da_thanh_toan = v_allocated where id = v_row.id;
        end if;
      end if;
    end loop;

    -- Non-obligation rows (still awaiting receipt qty, previous advances,
    -- etc.) get their paid amount re-derived from what's left in the pool,
    -- capped at what they already had, in row-creation order.
    for v_row in
      select d.* from debts d join v_debts vd on vd.id = d.id
      where d.doi_tuong_id = v_group.id and d.is_archived = false
        and not (vd.can_settle and vd.thanh_tien_thuc_nhan > 0)
      order by d.created_at asc
    loop
      v_allocated := round(least(greatest(v_remaining, 0), v_row.da_thanh_toan), 2);
      v_remaining := round(greatest(v_remaining - v_allocated, 0), 2);
      v_kept_count := v_kept_count + 1;
      if p_write then
        update debts set da_thanh_toan = v_allocated where id = v_row.id;
      end if;
    end loop;

    if v_remaining > 0 then
      v_preview := v_preview || jsonb_build_array(jsonb_build_object('action', 'advance', 'maCN', null, 'doiTuong', v_group.ten_doi_tuong, 'actual', 0, 'allocated', v_remaining));
      if p_write then
        insert into debts (ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no, mat_hang, don_gia, vat_rate, da_thanh_toan, ngay_tt_cuoi, ghi_chu, nguon_tao)
        values (next_code('TU'), v_now, v_now, v_group.id, v_group.ten_doi_tuong, 'TamUng', 'Tạm ứng/trả trước chưa đối trừ', 0, 0, v_remaining, v_now,
                'Tự tạo khi tất toán: phần tiền đã trả còn vượt tổng giá trị thực nhận của NCC sau khi tất toán các lô cũ.', 'WebApp');
      end if;
    end if;
  end loop;

  return jsonb_build_object('archived', v_archived_count, 'kept', v_kept_count, 'preview', v_preview);
end;
$$;

create or replace function rpc_preview_settlement(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_plan jsonb;
begin
  v_actor := require_permission('settlement:preview');
  v_plan := settlement_run_(v_actor, nullif(trim(coalesce(p_ma_doi_tuong, '')), ''), false);
  return jsonb_build_object('ok', true, 'plan', v_plan);
end;
$$;

create or replace function rpc_confirm_settlement(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_plan jsonb;
begin
  v_actor := require_permission('settlement:confirm');
  v_plan := settlement_run_(v_actor, nullif(trim(coalesce(p_ma_doi_tuong, '')), ''), true);
  perform write_audit(v_actor, 'CONFIRM_SETTLEMENT', 'debts', coalesce(p_ma_doi_tuong, 'ALL'), null, v_plan, 'OK', '');
  return jsonb_build_object('ok', true, 'archived', v_plan->'archived', 'kept', v_plan->'kept');
end;
$$;

grant execute on function rpc_get_debt_dashboard(jsonb) to authenticated;
grant execute on function rpc_preview_settlement(text) to authenticated;
grant execute on function rpc_confirm_settlement(text) to authenticated;
