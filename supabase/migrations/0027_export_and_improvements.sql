-- ============================================================================
-- 0027_export_and_improvements.sql
--   * improvements: người dùng gửi đề xuất cải tiến -> thông báo thẳng cho Admin.
--   * rpc_export_proposals / _payment_requests / _quotes: xuất RAW DATA theo
--     khoảng ngày để phân tích tổng thể (kèm trạng thái duyệt / nghiệm thu).
-- Quyền đọc: recent:read (mọi vai trò đăng nhập đều có); Admin bỏ qua.
-- ============================================================================

create table if not exists improvements (
  id uuid primary key default gen_random_uuid(),
  from_user uuid references profiles (id),
  from_name text,
  noi_dung text not null,
  trang_thai text not null default 'Mới',
  created_at timestamptz not null default now()
);
alter table improvements enable row level security;
revoke all on improvements from anon, authenticated;

create or replace function rpc_submit_improvement(p_noi_dung text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_name text; v_nd text := nullif(trim(coalesce(p_noi_dung,'')),''); v_id uuid;
begin
  if v_uid is null then raise exception 'Chưa đăng nhập.'; end if;
  if v_nd is null then raise exception 'Nội dung đề xuất cải tiến không được trống.'; end if;
  select name into v_name from profiles where id = v_uid;
  insert into improvements (from_user, from_name, noi_dung) values (v_uid, v_name, v_nd) returning id into v_id;
  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'improvement', 'Đề xuất cải tiến mới', coalesce(v_name,'') || ': ' || left(v_nd, 120), 'improve', v_id::text
  from profiles where role = 'Admin' and status = 'Hoạt động';
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Xuất phiếu đề xuất mua hàng (mỗi dòng vật tư 1 dòng) + trạng thái duyệt/nghiệm thu.
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
      'Nhà cung cấp', p.ten_doi_tuong,
      'Trong kế hoạch tuần', case when p.trong_ke_hoach_tuan then 'Có' else 'Không' end,
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
    where (p_from is null or p.ngay_de_xuat >= p_from) and (p_to is null or p.ngay_de_xuat <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- Xuất đề xuất thanh toán (mỗi dòng 1 dòng) + trạng thái duyệt.
create or replace function rpc_export_payment_requests(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('recent:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày', r->>'Mã ĐXTT'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Mã ĐXTT', pr.ma_de_xuat_tt,
      'Ngày', to_char(pr.ngay,'YYYY-MM-DD'),
      'Người lập', (select name from profiles where id=pr.nguoi_lap),
      'Trạng thái', pr.trang_thai,
      'Ngày duyệt', to_char(pr.approved_at,'YYYY-MM-DD'),
      'Nhà cung cấp', l.ncc,
      'Kế hoạch', l.ke_hoach,
      'Số tiền đề xuất', l.so_tien,
      'Nội dung', l.noi_dung,
      'Hình thức TT', l.hinh_thuc_tt,
      'Tình trạng hồ sơ', l.tinh_trang_ho_so,
      'Nối công nợ', case when l.debt_id is not null then 'Có' else 'Không' end
    ) as r
    from payment_requests pr
    join payment_request_lines l on l.request_id = pr.id
    where (p_from is null or pr.ngay >= p_from) and (p_to is null or pr.ngay <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- Xuất báo giá NCC theo ngày.
create or replace function rpc_export_quotes(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('recent:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Ngày', to_char(q.ngay,'YYYY-MM-DD'),
      'Mặt hàng', q.mat_hang,
      'Nhà cung cấp', q.ncc,
      'ĐVT', q.dvt,
      'Giá gọi', q.gia,
      'VAT', q.vat_status,
      'Đề xuất', q.de_xuat,
      'Ghi chú', q.ghi_chu,
      'Nguồn', q.nguon
    ) as r
    from price_quotes q
    where (p_from is null or q.ngay >= p_from) and (p_to is null or q.ngay <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

grant execute on function rpc_submit_improvement(text) to authenticated;
grant execute on function rpc_export_proposals(date, date) to authenticated;
grant execute on function rpc_export_payment_requests(date, date) to authenticated;
grant execute on function rpc_export_quotes(date, date) to authenticated;
