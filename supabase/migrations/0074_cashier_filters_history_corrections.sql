-- ============================================================================
-- 0074_cashier_filters_history_corrections.sql
--  Cashier UX follow-up:
--   * default/filter cashier queue by payment-request date
--   * track which cashier/payment row confirmed each line
--   * expose cashier paid history with proof and upstream DXMH evidence
--   * allow cashier to request Admin correction, and Admin to reopen the line
--   * accept private business-attachment paths in upload guardrails
-- ============================================================================

alter table payment_request_lines add column if not exists cashier_payment_id uuid references payments (id) on delete set null;
alter table payment_request_lines add column if not exists cashier_paid_by uuid references profiles (id);
alter table payment_request_lines add column if not exists cashier_correction_requested_at timestamptz;
alter table payment_request_lines add column if not exists cashier_correction_reason text;
alter table payment_request_lines add column if not exists cashier_correction_status text;
alter table payment_request_lines add column if not exists cashier_correction_admin_note text;
alter table payment_request_lines add column if not exists cashier_correction_returned_at timestamptz;
alter table payment_request_lines add column if not exists cashier_correction_returned_by uuid references profiles (id);

create index if not exists idx_payreq_lines_paid_at on payment_request_lines (paid_at);
create index if not exists idx_payreq_lines_cashier_paid_by on payment_request_lines (cashier_paid_by);
create index if not exists idx_payreq_lines_cashier_correction_status on payment_request_lines (cashier_correction_status);

create or replace function app_validate_upload_attachments(p_files jsonb, p_context text default 'file')
returns void
language plpgsql stable as $$
declare
  v_file jsonb;
  v_idx int := 0;
  v_name text;
  v_bucket text;
  v_path text;
  v_path_after_owner text;
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
    v_path_after_owner := case
      when position('/' in coalesce(v_path, '')) > 0 then substring(v_path from position('/' in v_path) + 1)
      else coalesce(v_path, '')
    end;

    if v_name is null or v_path is null then
      raise exception '% #% thiếu tên tệp hoặc đường dẫn lưu trữ.', v_label, v_idx;
    end if;

    if v_bucket not in ('attachments', 'business-attachments') then
      raise exception 'Tệp "%" phải nằm trong kho lưu trữ attachments/business-attachments của hệ thống.', v_name;
    end if;

    if not exists (
      select 1
      from unnest(v_prefixes) as p(prefix)
      where (v_bucket = 'attachments' and v_path like p.prefix || '%')
         or (v_bucket = 'business-attachments' and v_path_after_owner like p.prefix || '%')
    ) then
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

drop function if exists rpc_get_cashier_queue();
create or replace function rpc_get_receipt_review(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('receipt:review');

  select coalesce(jsonb_agg(x order by (x->>'ngayNhan') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maCN', d.ma_cn,
      'maDeXuat', p.ma_de_xuat,
      'maDoiTuong', dt.ma_doi_tuong,
      'tenDoiTuong', d.ten_doi_tuong,
      'boPhan', coalesce(dep.ten, p.bo_phan),
      'nguoiDeNghi', p.nguoi_de_nghi,
      'matHang', d.mat_hang,
      'dvt', (select dvt from materials m where m.id = d.material_id),
      'slDat', d.sl_dat,
      'slThucNhan', d.sl_thuc_nhan,
      'donGia', d.don_gia,
      'vatRate', d.vat_rate,
      'thanhTienThucNhan', round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
      'daThanhToan', d.da_thanh_toan,
      'hanThanhToan', to_char(d.han_thanh_toan, 'YYYY-MM-DD'),
      'ngayNhan', to_char(d.ngay_nhan, 'YYYY-MM-DD'),
      'dieuKhoanTT', d.dieu_khoan_tt,
      'chungTuTypes', coalesce(d.chung_tu_types, '[]'::jsonb),
      'nghiemThuFiles', coalesce(d.nghiem_thu_files, '[]'::jsonb),
      'baoGia', coalesce(p.attachments, '[]'::jsonb)
    ) as x
    from debts d
    left join proposals p on p.id = d.proposal_id
    left join departments dep on dep.id = p.department_id
    left join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false
      and d.sl_thuc_nhan is not null
      and d.cong_no_confirmed = false
      and not d.prepay
      and d.cho_bo_sung = false
    order by d.ngay_nhan desc nulls last
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) t;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_get_cashier_queue(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('payment:execute');

  select coalesce(jsonb_agg(x order by (x->>'ngay') asc, (x->>'maDeXuatTT') asc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maDeXuatTT', pr.ma_de_xuat_tt,
      'ngay', to_char(pr.ngay, 'YYYY-MM-DD'),
      'nguoiLap', (select name from profiles where id = pr.nguoi_lap),
      'tong', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr.id), 0),
      'daChuyen', coalesce((select sum(coalesce(so_tien_da_chuyen, so_tien)) from payment_request_lines where request_id = pr.id and paid), 0),
      'lines', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'lineId', l.id,
          'ncc', l.ncc,
          'soTien', l.so_tien,
          'soTienDaChuyen', l.so_tien_da_chuyen,
          'noiDung', l.noi_dung,
          'hinhThucTT', l.hinh_thuc_tt,
          'maCN', d.ma_cn,
          'maDeXuat', p.ma_de_xuat,
          'boPhan', coalesce(dep.ten, p.bo_phan),
          'nguoiDeNghi', p.nguoi_de_nghi,
          'matHang', d.mat_hang,
          'ngayNhan', to_char(d.ngay_nhan, 'YYYY-MM-DD'),
          'soHoaDonVat', d.so_hoa_don_vat,
          'soTk', dt.so_tk_ngan_hang,
          'chiNhanh', dt.chi_nhanh_ngan_hang,
          'mst', dt.mst,
          'chungTuTypes', coalesce(d.chung_tu_types, '[]'::jsonb),
          'chungTu', coalesce(d.nghiem_thu_files, '[]'::jsonb),
          'baoGia', coalesce(p.attachments, '[]'::jsonb),
          'paid', l.paid,
          'paidAt', to_char(l.paid_at, 'YYYY-MM-DD HH24:MI'),
          'paidProof', coalesce(l.proof_files, '[]'::jsonb)
        ) order by l.created_at), '[]'::jsonb)
        from payment_request_lines l
        left join doi_tuong dt on dt.id = l.doi_tuong_id
        left join debts d on d.id = l.debt_id
        left join proposals p on p.id = d.proposal_id
        left join departments dep on dep.id = p.department_id
        where l.request_id = pr.id and l.paid = false
      )
    ) as x
    from payment_requests pr
    where pr.trang_thai = 'Đã duyệt'
      and (p_from is null or pr.ngay >= p_from)
      and (p_to is null or pr.ngay <= p_to)
      and exists (select 1 from payment_request_lines l where l.request_id = pr.id and l.paid = false)
  ) t;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

drop function if exists rpc_cashier_pay_line(uuid, jsonb, numeric, text);
create or replace function rpc_cashier_pay_line(
  p_line_id uuid,
  p_proof jsonb default '[]'::jsonb,
  p_amount numeric default null,
  p_hinh_thuc text default 'CK'
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_line payment_request_lines;
  v_pr payment_requests;
  v_dt doi_tuong;
  v_ma_cn text;
  v_ma_tt text;
  v_pay_id uuid;
  v_creator uuid;
  v_ma_dx text;
  v_remaining int;
  v_amt numeric;
  v_du numeric;
  v_ht text;
begin
  v_actor := require_permission('payment:execute');
  v_ht := case when p_hinh_thuc = 'Tiền mặt' then 'Tiền mặt' else 'CK' end;

  select * into v_line from payment_request_lines where id = p_line_id for update;
  if v_line is null then raise exception 'Không tìm thấy khoản chi.'; end if;
  if v_line.paid then raise exception 'Khoản này đã được xác nhận chuyển rồi.'; end if;

  select * into v_pr from payment_requests where id = v_line.request_id;
  if v_pr.trang_thai <> 'Đã duyệt' then
    raise exception 'Chỉ chuyển tiền sau khi đề xuất % đã được lãnh đạo DUYỆT.', v_pr.ma_de_xuat_tt;
  end if;

  v_amt := coalesce(p_amount, v_line.so_tien);
  if v_amt <= 0 then raise exception 'Số tiền đã chuyển phải > 0.'; end if;

  v_ma_cn := null;
  v_creator := null;
  v_ma_dx := null;
  if v_line.debt_id is not null then
    select ma_cn into v_ma_cn from debts where id = v_line.debt_id;
    select p.nguoi_tao, p.ma_de_xuat into v_creator, v_ma_dx
      from debts d left join proposals p on p.id = d.proposal_id where d.id = v_line.debt_id;
    select so_tien_con_lai into v_du from v_debts where id = v_line.debt_id;
    if round(v_amt) > round(coalesce(v_du, 0)) + 1 then
      raise exception 'Số tiền đã chuyển (% đ) VƯỢT số dư còn lại (% đ) của khoản %. Kiểm tra lại.',
        to_char(v_amt, 'FM999,999,999'), to_char(coalesce(v_du, 0), 'FM999,999,999'), v_ma_cn;
    end if;
  end if;

  if v_line.doi_tuong_id is not null then
    select * into v_dt from doi_tuong where id = v_line.doi_tuong_id;
  else
    v_dt := ensure_doi_tuong(null, v_line.ncc, 'NCC', null, null, null, null);
  end if;

  v_ma_tt := next_code('TT');
  insert into payments (
    ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien,
    phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai, proof_files
  )
  values (
    v_ma_tt, current_date, v_dt.id, v_dt.ten_doi_tuong, v_amt,
    case when v_line.debt_id is not null then 'MA_CN' else 'FIFO' end,
    v_ma_cn, null, format('Chi %s theo ĐXTT %s | %s', v_ht, v_pr.ma_de_xuat_tt, coalesce(v_line.noi_dung, '')),
    v_actor.id, 'Đã ghi nhận', coalesce(p_proof, '[]'::jsonb)
  )
  returning id into v_pay_id;

  if v_line.debt_id is not null then
    insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
    values (v_pay_id, v_line.debt_id, v_ma_cn, v_amt);
    update debts set da_thanh_toan = da_thanh_toan + v_amt, ngay_tt_cuoi = current_date where id = v_line.debt_id;
    if v_creator is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (
        v_creator, 'payment_done', 'Khoản của bạn đã được chuyển tiền',
        coalesce(v_ma_dx, '') || ' · ' || coalesce(v_ma_cn, '') || ' · ' || to_char(v_amt, 'FM999,999,999') || 'đ (' || v_ht || ', thủ quỹ: ' || coalesce(v_actor.name, '') || ')',
        'proposal', coalesce(v_ma_dx, v_ma_cn)
      );
    end if;
  end if;

  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'payment_done', 'Thủ quỹ đã chi 1 khoản',
         v_pr.ma_de_xuat_tt || ' · ' || coalesce(v_ma_cn, v_line.ncc, '') || ' · ' || to_char(v_amt, 'FM999,999,999') || 'đ (' || v_ht || ')',
         'debtpay', v_pr.ma_de_xuat_tt
  from profiles where role in ('KeToanCongNo', 'Admin') and status = 'Hoạt động';

  update payment_request_lines
  set paid = true,
      paid_at = now(),
      proof_files = coalesce(p_proof, '[]'::jsonb),
      so_tien_da_chuyen = v_amt,
      hinh_thuc_tt = v_ht,
      cashier_payment_id = v_pay_id,
      cashier_paid_by = v_actor.id,
      cashier_correction_requested_at = null,
      cashier_correction_reason = null,
      cashier_correction_status = null,
      cashier_correction_admin_note = null,
      cashier_correction_returned_at = null,
      cashier_correction_returned_by = null
  where id = v_line.id;

  select count(*) into v_remaining from payment_request_lines where request_id = v_pr.id and paid = false;
  if v_remaining = 0 then
    update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id;
  end if;

  perform write_audit(v_actor, 'CASHIER_PAY_LINE', 'payment_request_lines', v_line.id::text, to_jsonb(v_line),
    jsonb_build_object('amount', v_amt, 'hinhThuc', v_ht, 'paymentId', v_pay_id, 'remaining', v_remaining), 'OK', 'Thủ quỹ xác nhận chi 1 khoản.');

  return jsonb_build_object('ok', true, 'maDeXuatTT', v_pr.ma_de_xuat_tt, 'remaining', v_remaining);
end;
$$;

create or replace function rpc_get_cashier_paid_history(p_from date default current_date, p_to date default current_date)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_from date := coalesce(p_from, current_date);
  v_to date := coalesce(p_to, current_date);
  v_rows jsonb;
begin
  v_actor := require_permission('payment:execute');
  if v_from > v_to then
    raise exception 'Khoảng ngày không hợp lệ.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'lineId', l.id,
    'maDeXuatTT', pr.ma_de_xuat_tt,
    'ngayDeXuatTT', to_char(pr.ngay, 'YYYY-MM-DD'),
    'nguoiLap', lap.name,
    'ncc', l.ncc,
    'noiDung', l.noi_dung,
    'hinhThucTT', l.hinh_thuc_tt,
    'soTienDeXuat', l.so_tien,
    'soTienDaChuyen', coalesce(l.so_tien_da_chuyen, l.so_tien),
    'paidAt', to_char(l.paid_at, 'YYYY-MM-DD HH24:MI'),
    'maThanhToan', pm.ma_thanh_toan,
    'proof', coalesce(l.proof_files, pm.proof_files, '[]'::jsonb),
    'soTk', dt.so_tk_ngan_hang,
    'chiNhanh', dt.chi_nhanh_ngan_hang,
    'mst', dt.mst,
    'correctionStatus', l.cashier_correction_status,
    'correctionReason', l.cashier_correction_reason,
    'correctionRequestedAt', to_char(l.cashier_correction_requested_at, 'YYYY-MM-DD HH24:MI'),
    'correctionAdminNote', l.cashier_correction_admin_note,
    'maCN', d.ma_cn,
    'maDeXuat', p.ma_de_xuat,
    'ngayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
    'boPhan', coalesce(dep.ten, p.bo_phan),
    'nguoiDeNghi', p.nguoi_de_nghi,
    'tenDoiTuong', coalesce(d.ten_doi_tuong, l.ncc),
    'matHang', d.mat_hang,
    'dvt', m.dvt,
    'slDat', d.sl_dat,
    'slThucNhan', d.sl_thuc_nhan,
    'donGia', d.don_gia,
    'vatRate', d.vat_rate,
    'thanhTienThucNhan', case when d.sl_thuc_nhan is not null then round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2) else null end,
    'hanThanhToan', to_char(d.han_thanh_toan, 'YYYY-MM-DD'),
    'ngayNhan', to_char(d.ngay_nhan, 'YYYY-MM-DD'),
    'soHoaDonVat', d.so_hoa_don_vat,
    'chungTuTypes', coalesce(d.chung_tu_types, '[]'::jsonb),
    'nghiemThuFiles', coalesce(d.nghiem_thu_files, '[]'::jsonb),
    'baoGia', coalesce(p.attachments, '[]'::jsonb)
  ) order by l.paid_at desc, pr.ma_de_xuat_tt), '[]'::jsonb)
    into v_rows
  from payment_request_lines l
  join payment_requests pr on pr.id = l.request_id
  left join payments pm on pm.id = l.cashier_payment_id
  left join doi_tuong dt on dt.id = l.doi_tuong_id
  left join profiles lap on lap.id = pr.nguoi_lap
  left join debts d on d.id = l.debt_id
  left join proposals p on p.id = d.proposal_id
  left join departments dep on dep.id = p.department_id
  left join materials m on m.id = d.material_id
  where l.paid = true
    and l.paid_at::date between v_from and v_to
    and (l.cashier_paid_by = v_actor.id or pm.nguoi_nhap = v_actor.id);

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_request_cashier_payment_correction(p_line_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_line payment_request_lines;
  v_pr payment_requests;
  v_payment payments;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  v_actor := require_permission('payment:execute');
  if v_reason is null then raise exception 'Cần nhập giải trình cần sửa.'; end if;

  select * into v_line from payment_request_lines where id = p_line_id for update;
  if v_line is null then raise exception 'Không tìm thấy khoản chi.'; end if;
  if not v_line.paid then raise exception 'Khoản này chưa được xác nhận chi.'; end if;

  select * into v_payment from payments where id = v_line.cashier_payment_id;
  if v_line.cashier_paid_by is distinct from v_actor.id
     and coalesce(v_payment.nguoi_nhap, '00000000-0000-0000-0000-000000000000'::uuid) is distinct from v_actor.id then
    raise exception 'Chỉ thủ quỹ đã xác nhận khoản này mới được yêu cầu sửa.';
  end if;

  select * into v_pr from payment_requests where id = v_line.request_id;
  update payment_request_lines
  set cashier_correction_requested_at = now(),
      cashier_correction_reason = v_reason,
      cashier_correction_status = 'Chờ admin',
      cashier_correction_admin_note = null
  where id = p_line_id;

  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'cashier_correction_request', 'Thủ quỹ yêu cầu sửa khoản chi',
         v_pr.ma_de_xuat_tt || ' · ' || coalesce(v_line.ncc, '') || ' · ' || v_reason,
         'users', p_line_id::text
  from profiles
  where role = 'Admin' and status = 'Hoạt động';

  perform write_audit(v_actor, 'REQUEST_CASHIER_PAYMENT_CORRECTION', 'payment_request_lines', p_line_id::text, to_jsonb(v_line),
    jsonb_build_object('reason', v_reason, 'maDeXuatTT', v_pr.ma_de_xuat_tt), 'OK', 'Thủ quỹ yêu cầu Admin trả lại khoản chi để sửa.');

  return jsonb_build_object('ok', true, 'lineId', p_line_id);
end;
$$;

create or replace function rpc_admin_list_cashier_correction_requests(p_limit int default 100)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('user:manage');

  select coalesce(jsonb_agg(jsonb_build_object(
    'lineId', l.id,
    'maDeXuatTT', pr.ma_de_xuat_tt,
    'ncc', l.ncc,
    'noiDung', l.noi_dung,
    'soTienDaChuyen', coalesce(l.so_tien_da_chuyen, l.so_tien),
    'paidAt', to_char(l.paid_at, 'YYYY-MM-DD HH24:MI'),
    'cashier', coalesce(cashier.name, cashier.email),
    'reason', l.cashier_correction_reason,
    'requestedAt', to_char(l.cashier_correction_requested_at, 'YYYY-MM-DD HH24:MI'),
    'maCN', d.ma_cn,
    'maThanhToan', pm.ma_thanh_toan,
    'proof', coalesce(l.proof_files, '[]'::jsonb)
  ) order by l.cashier_correction_requested_at desc), '[]'::jsonb)
    into v_rows
  from (
    select *
    from payment_request_lines
    where cashier_correction_status = 'Chờ admin'
    order by cashier_correction_requested_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) l
  join payment_requests pr on pr.id = l.request_id
  left join profiles cashier on cashier.id = l.cashier_paid_by
  left join debts d on d.id = l.debt_id
  left join payments pm on pm.id = l.cashier_payment_id;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_admin_return_cashier_payment(p_line_id uuid, p_reason text default '')
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_line payment_request_lines;
  v_pr payment_requests;
  v_payment payments;
  v_note text := nullif(trim(coalesce(p_reason, '')), '');
  r record;
begin
  v_actor := require_permission('user:manage');
  if v_note is null then raise exception 'Cần nhập ghi chú trả lại.'; end if;

  select * into v_line from payment_request_lines where id = p_line_id for update;
  if v_line is null then raise exception 'Không tìm thấy khoản chi.'; end if;
  if not v_line.paid then raise exception 'Khoản này hiện chưa ở trạng thái đã chi.'; end if;
  if v_line.cashier_payment_id is null then
    raise exception 'Khoản chi này chưa gắn payment_id để tự động trả lại. Hãy nhờ KTTH điều chỉnh thủ công.';
  end if;

  select * into v_pr from payment_requests where id = v_line.request_id for update;
  select * into v_payment from payments where id = v_line.cashier_payment_id for update;
  if v_payment is null then raise exception 'Không tìm thấy bút toán thanh toán đã ghi.'; end if;

  for r in select * from payment_allocations where payment_id = v_payment.id loop
    if r.debt_id is not null then
      update debts
      set da_thanh_toan = greatest(da_thanh_toan - r.so_tien_phan_bo, 0),
          is_archived = false,
          archived_at = null,
          archived_by = null
      where id = r.debt_id;
    end if;
  end loop;

  delete from payment_allocations where payment_id = v_payment.id;
  delete from payments where id = v_payment.id;

  update payment_request_lines
  set paid = false,
      paid_at = null,
      proof_files = '[]'::jsonb,
      so_tien_da_chuyen = null,
      cashier_payment_id = null,
      cashier_correction_status = 'Đã trả lại',
      cashier_correction_admin_note = v_note,
      cashier_correction_returned_at = now(),
      cashier_correction_returned_by = v_actor.id
  where id = p_line_id;

  update payment_requests
  set trang_thai = 'Đã duyệt',
      executed_at = null,
      updated_at = now()
  where id = v_pr.id;

  if v_line.cashier_paid_by is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (
      v_line.cashier_paid_by, 'cashier_correction_returned', 'Admin đã trả lại khoản chi để sửa',
      v_pr.ma_de_xuat_tt || ' · ' || coalesce(v_line.ncc, '') || ' · ' || v_note,
      'cashier', p_line_id::text
    );
  end if;

  perform write_audit(v_actor, 'ADMIN_RETURN_CASHIER_PAYMENT', 'payment_request_lines', p_line_id::text,
    jsonb_build_object('line', to_jsonb(v_line), 'payment', to_jsonb(v_payment)),
    jsonb_build_object('reason', v_note, 'maDeXuatTT', v_pr.ma_de_xuat_tt), 'OK', 'Admin trả lại khoản chi để thủ quỹ sửa.');

  return jsonb_build_object('ok', true, 'lineId', p_line_id, 'maDeXuatTT', v_pr.ma_de_xuat_tt);
end;
$$;

revoke all on function app_validate_upload_attachments(jsonb, text) from public, anon, authenticated;
revoke all on function rpc_get_receipt_review(int) from public, anon;
revoke all on function rpc_get_cashier_queue(date, date) from public, anon;
revoke all on function rpc_cashier_pay_line(uuid, jsonb, numeric, text) from public, anon;
revoke all on function rpc_get_cashier_paid_history(date, date) from public, anon;
revoke all on function rpc_request_cashier_payment_correction(uuid, text) from public, anon;
revoke all on function rpc_admin_list_cashier_correction_requests(int) from public, anon;
revoke all on function rpc_admin_return_cashier_payment(uuid, text) from public, anon;

grant execute on function rpc_get_receipt_review(int) to authenticated;
grant execute on function rpc_get_cashier_queue(date, date) to authenticated;
grant execute on function rpc_cashier_pay_line(uuid, jsonb, numeric, text) to authenticated;
grant execute on function rpc_get_cashier_paid_history(date, date) to authenticated;
grant execute on function rpc_request_cashier_payment_correction(uuid, text) to authenticated;
grant execute on function rpc_admin_list_cashier_correction_requests(int) to authenticated;
grant execute on function rpc_admin_return_cashier_payment(uuid, text) to authenticated;
