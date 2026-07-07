-- ============================================================================
-- 0075_payreq_outside_debt_lines.sql
-- Clarify the approved path for payment-request lines that are not linked to a
-- standard debt record: KTTH may include them in DXTT with internal explanation;
-- cashier payment records the disbursement but does not reduce a VAT/debt row.
-- ============================================================================

create or replace function rpc_create_payment_request(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_status text := case when coalesce(p_payload->>'status','Chờ duyệt') = 'Nháp' then 'Nháp' else 'Chờ duyệt' end;
  v_id uuid;
  v_ma text;
  v_line jsonb;
  v_debt debts;
  v_debt_id uuid;
  v_dt_id uuid;
  v_ncc text;
  v_sotien numeric;
  v_giaitrinh text;
  v_hoso text;
  v_count int := 0;
  v_outside_count int := 0;
begin
  v_actor := require_permission('payment:request');
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines') = 0 then
    raise exception 'Đề xuất thanh toán cần ít nhất một dòng.';
  end if;

  v_ma := next_code('PT');
  insert into payment_requests (ma_de_xuat_tt, ngay, nguoi_lap, trang_thai, ghi_chu)
  values (v_ma, coalesce((p_payload->>'ngay')::date, current_date), v_actor.id, v_status, p_payload->>'ghiChu')
  returning id into v_id;

  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_sotien := parse_number(v_line->>'soTien');
    if v_sotien is null or v_sotien <= 0 then
      continue;
    end if;

    v_debt := null;
    v_debt_id := nullif(v_line->>'debtId','')::uuid;
    v_dt_id := null;
    v_ncc := nullif(trim(coalesce(v_line->>'ncc','')),'');
    v_giaitrinh := nullif(trim(coalesce(v_line->>'giaiTrinh','')),'');
    v_hoso := nullif(trim(coalesce(v_line->>'tinhTrangHoSo','')),'');

    if v_debt_id is not null then
      select * into v_debt from debts where id = v_debt_id;
      if v_debt is not null then
        v_dt_id := v_debt.doi_tuong_id;
        v_ncc := coalesce(v_ncc, v_debt.ten_doi_tuong);
      end if;
      v_hoso := coalesce(v_hoso, 'Đã có hồ sơ');
    else
      v_outside_count := v_outside_count + 1;
      v_hoso := coalesce(v_hoso, 'Ngoài công nợ - giải trình nội bộ');
      if v_status = 'Chờ duyệt' and v_giaitrinh is null then
        raise exception 'Dòng "%" ngoài công nợ/chưa đủ chứng từ — cần nhập giải trình nội bộ.', coalesce(v_ncc,'(chưa có NCC)');
      end if;
    end if;

    if v_ncc is null then
      raise exception 'Mỗi dòng cần có tên nhà cung cấp.';
    end if;

    insert into payment_request_lines (
      request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien,
      noi_dung, hinh_thuc_tt, tinh_trang_ho_so, giai_trinh
    ) values (
      v_id,
      v_debt_id,
      v_dt_id,
      v_ncc,
      coalesce(parse_number(v_line->>'keHoach'), 0),
      v_sotien,
      v_line->>'noiDung',
      case when coalesce(v_line->>'hinhThucTT','CK') = 'Tiền mặt' then 'Tiền mặt' else 'CK' end,
      v_hoso,
      v_giaitrinh
    );
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Đề xuất thanh toán cần ít nhất một dòng có số tiền hợp lệ.';
  end if;
  if v_status = 'Chờ duyệt' then
    perform notify_payreq_pending_(v_id, v_ma, v_actor.name);
  end if;

  perform write_audit(v_actor, 'CREATE_PAYMENT_REQUEST', 'payment_requests', v_ma, null,
    jsonb_build_object('lines', v_count, 'outsideDebtLines', v_outside_count, 'status', v_status), 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuatTT', v_ma, 'status', v_status, 'lines', v_count);
end;
$$;

create or replace function rpc_update_payment_request(p_ma text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_pr payment_requests;
  v_status text := case when coalesce(p_payload->>'status','Nháp') = 'Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_line jsonb;
  v_sotien numeric;
  v_ncc text;
  v_giaitrinh text;
  v_hoso text;
  v_dt_id uuid;
  v_debt debts;
  v_debt_id uuid;
  v_count int := 0;
  v_outside_count int := 0;
begin
  v_actor := require_permission('payment:request');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then
    raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma;
  end if;
  if v_pr.trang_thai <> 'Nháp' then
    raise exception 'Chỉ sửa được phiếu đang Nháp.';
  end if;

  update payment_requests
  set ngay = coalesce((p_payload->>'ngay')::date, ngay),
      ghi_chu = p_payload->>'ghiChu',
      trang_thai = v_status,
      ly_do_tra_lai = case when v_status = 'Chờ duyệt' then null else ly_do_tra_lai end
  where id = v_pr.id;

  delete from payment_request_lines where request_id = v_pr.id;

  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_sotien := parse_number(v_line->>'soTien');
    if v_sotien is null or v_sotien <= 0 then
      continue;
    end if;

    v_debt := null;
    v_debt_id := nullif(v_line->>'debtId','')::uuid;
    v_dt_id := null;
    v_ncc := nullif(trim(coalesce(v_line->>'ncc','')),'');
    v_giaitrinh := nullif(trim(coalesce(v_line->>'giaiTrinh','')),'');
    v_hoso := nullif(trim(coalesce(v_line->>'tinhTrangHoSo','')),'');

    if v_debt_id is not null then
      select * into v_debt from debts where id = v_debt_id;
      if v_debt is not null then
        v_dt_id := v_debt.doi_tuong_id;
        v_ncc := coalesce(v_ncc, v_debt.ten_doi_tuong);
      end if;
      v_hoso := coalesce(v_hoso, 'Đã có hồ sơ');
    else
      v_outside_count := v_outside_count + 1;
      v_hoso := coalesce(v_hoso, 'Ngoài công nợ - giải trình nội bộ');
      if v_status = 'Chờ duyệt' and v_giaitrinh is null then
        raise exception 'Dòng "%" ngoài công nợ/chưa đủ chứng từ — cần nhập giải trình nội bộ.', coalesce(v_ncc,'(chưa có NCC)');
      end if;
    end if;

    if v_ncc is null then
      raise exception 'Mỗi dòng cần có tên nhà cung cấp.';
    end if;

    insert into payment_request_lines (
      request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien,
      noi_dung, hinh_thuc_tt, tinh_trang_ho_so, giai_trinh
    ) values (
      v_pr.id,
      v_debt_id,
      v_dt_id,
      v_ncc,
      coalesce(parse_number(v_line->>'keHoach'), 0),
      v_sotien,
      v_line->>'noiDung',
      case when coalesce(v_line->>'hinhThucTT','CK') = 'Tiền mặt' then 'Tiền mặt' else 'CK' end,
      v_hoso,
      v_giaitrinh
    );
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Đề xuất thanh toán cần ít nhất một dòng có số tiền.';
  end if;
  if v_status = 'Chờ duyệt' then
    perform notify_payreq_pending_(v_pr.id, p_ma, v_actor.name);
  end if;

  perform write_audit(v_actor, 'UPDATE_PAYMENT_REQUEST', 'payment_requests', p_ma, to_jsonb(v_pr),
    jsonb_build_object('lines', v_count, 'outsideDebtLines', v_outside_count, 'status', v_status), 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma, 'status', v_status);
end;
$$;

create or replace function rpc_get_pending_payreq_grouped() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('payment:approve');
  select coalesce(jsonb_agg(day_json order by day_json->>'ngay' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'ngay', to_char(pr.ngay,'YYYY-MM-DD'),
      'soPhieu', count(distinct pr.id),
      'tong', coalesce(sum(l.so_tien), 0),
      'boPhan', (
        select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'tong', t) order by t desc), '[]'::jsonb)
        from (
          select case
              when ll.debt_id is null then 'Ngoài công nợ/chưa đủ chứng từ'
              else coalesce(pp.bo_phan, '(không rõ)')
            end as bp,
            sum(ll.so_tien) as t
          from payment_requests pr2
          join payment_request_lines ll on ll.request_id = pr2.id
          left join debts dd on dd.id = ll.debt_id
          left join proposals pp on pp.id = dd.proposal_id
          where pr2.trang_thai = 'Chờ duyệt' and pr2.ngay = pr.ngay
          group by 1
        ) s
      ),
      'phieu', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'maDeXuatTT', pr3.ma_de_xuat_tt,
          'nguoiLap', (select name from profiles where id = pr3.nguoi_lap),
          'tong', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr3.id), 0),
          'lines', (
            select coalesce(jsonb_agg(jsonb_build_object(
              'ncc', l3.ncc,
              'soTien', l3.so_tien,
              'noiDung', l3.noi_dung,
              'hinhThucTT', l3.hinh_thuc_tt,
              'tinhTrangHoSo', l3.tinh_trang_ho_so,
              'giaiTrinh', l3.giai_trinh,
              'linked', (l3.debt_id is not null),
              'maCN', d3.ma_cn,
              'matHang', d3.mat_hang,
              'boPhan', case when l3.debt_id is null then 'Ngoài công nợ/chưa đủ chứng từ' else pp3.bo_phan end
            ) order by l3.created_at), '[]'::jsonb)
            from payment_request_lines l3
            left join debts d3 on d3.id = l3.debt_id
            left join proposals pp3 on pp3.id = d3.proposal_id
            where l3.request_id = pr3.id
          )
        ) order by pr3.created_at), '[]'::jsonb)
        from payment_requests pr3
        where pr3.trang_thai = 'Chờ duyệt' and pr3.ngay = pr.ngay
      )
    ) as day_json
    from payment_requests pr
    join payment_request_lines l on l.request_id = pr.id
    where pr.trang_thai = 'Chờ duyệt'
    group by pr.ngay
  ) t;
  return jsonb_build_object('ok', true, 'days', v_rows);
end;
$$;

create or replace function rpc_export_payment_requests(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('payment:request:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày', r->>'Mã ĐXTT'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Mã ĐXTT', pr.ma_de_xuat_tt,
      'Ngày', to_char(pr.ngay,'YYYY-MM-DD'),
      'Người lập', (select name from profiles where id=pr.nguoi_lap),
      'Trạng thái', pr.trang_thai,
      'Ngày duyệt', to_char(pr.approved_at,'YYYY-MM-DD'),
      'Loại dòng', case when l.debt_id is null then 'Ngoài công nợ/chưa đủ chứng từ' else 'Công nợ chuẩn' end,
      'Nhà cung cấp', l.ncc,
      'Kế hoạch', l.ke_hoach,
      'Số tiền đề xuất', l.so_tien,
      'Nội dung', l.noi_dung,
      'Hình thức TT', l.hinh_thuc_tt,
      'Tình trạng hồ sơ', l.tinh_trang_ho_so,
      'Giải trình nội bộ', l.giai_trinh,
      'Nối công nợ', case when l.debt_id is not null then 'Có' else 'Không' end
    ) as r
    from payment_requests pr
    join payment_request_lines l on l.request_id = pr.id
    where (p_from is null or pr.ngay >= p_from)
      and (p_to is null or pr.ngay <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

grant execute on function rpc_create_payment_request(jsonb) to authenticated;
grant execute on function rpc_update_payment_request(text, jsonb) to authenticated;
grant execute on function rpc_get_pending_payreq_grouped() to authenticated;
grant execute on function rpc_export_payment_requests(date, date) to authenticated;
