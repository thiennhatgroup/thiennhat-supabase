-- ============================================================================
-- 0047_receipt_accounting_gate.sql  (Đợt E)
--  Đổi luồng: NVMH chỉ tới bước NHẬN HÀNG (nhập SL thực nhận + tick loại chứng
--  từ + đính kèm). Khoản CHƯA thành công nợ. Kế toán có bước riêng: kiểm tra
--  chứng từ, ghi số đã trả trước (nếu có), rồi "LƯU VỀ CÔNG NỢ" (hoặc TRẢ LẠI
--  NVMH bổ sung). Chỉ khoản đã "lưu công nợ" (hoặc trả trước) mới vào các màn
--  thanh toán / theo dõi công nợ.
-- ============================================================================

alter table debts add column if not exists cong_no_confirmed boolean not null default false;
alter table debts add column if not exists cong_no_confirmed_at timestamptz;
alter table debts add column if not exists cong_no_confirmed_by uuid references profiles (id);
alter table debts add column if not exists chung_tu_types jsonb not null default '[]'::jsonb;
alter table debts add column if not exists cho_bo_sung boolean not null default false;
alter table debts add column if not exists ly_do_bo_sung text;

-- Công nợ CŨ (đã nghiệm thu trước khi có bước này) coi như đã lưu công nợ, để
-- không kẹt dữ liệu đang chạy.
update debts set cong_no_confirmed = true
  where cong_no_confirmed = false and sl_thuc_nhan is not null;

insert into role_permissions (role, permission) values
  ('KeToanCongNo', 'congno:confirm'), ('KeToanCongNo', 'receipt:review')
on conflict (role, permission) do nothing;
-- NVMH chỉ tới bước nhận hàng — bỏ quyền ghi thanh toán (kế toán phụ trách).
delete from role_permissions where role = 'NhanVienMuaHang' and permission = 'payment:create';

-- ---- v_debts: thêm cờ la_cong_no + trạng thái theo bước kế toán --------------
drop view if exists v_debts;
create view v_debts as
select
  d.*,
  round(coalesce(d.sl_dat, 0) * d.don_gia * (1 + d.vat_rate), 2) as thanh_tien_dat,
  round(case
          when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
          when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate)
          else 0 end, 2) as thanh_tien_thuc_nhan,
  round(
    (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
          when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end)
    - d.da_thanh_toan, 2) as so_tien_con_lai,
  (d.cong_no_confirmed or d.prepay) as la_cong_no,
  case
    when (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
               when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan <= 0 then 0
    when d.han_thanh_toan is null then 0
    else greatest(0, (current_date - d.han_thanh_toan))
  end as so_ngay_qua_han,
  case
    when d.sl_thuc_nhan is null and not d.prepay and d.da_thanh_toan = 0 then 'Chờ nghiệm thu'
    when d.sl_thuc_nhan is null and d.prepay and d.da_thanh_toan = 0 then 'Trả trước - chờ nhận hàng'
    when d.sl_thuc_nhan is not null and not d.cong_no_confirmed and not d.prepay and d.cho_bo_sung then 'Cần bổ sung chứng từ'
    when d.sl_thuc_nhan is not null and not d.cong_no_confirmed and not d.prepay then 'Chờ kế toán duyệt chứng từ'
    when (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
               when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan < 0 then 'Trả dư/đối trừ'
    when abs((case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
                   when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan) < 1 then 'Đã tất toán'
    when d.han_thanh_toan is null then 'Cần nhập hạn TT'
    when greatest(0, (current_date - d.han_thanh_toan)) > 0 then 'Quá hạn'
    else 'Theo dõi'
  end as trang_thai_dong,
  ((d.cong_no_confirmed or d.prepay)
    and ((d.sl_thuc_nhan is not null and (d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)) > 0)
      or (d.prepay and coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) > 0))) as can_settle
from debts d;

-- ---- NVMH nghiệm thu: KHÔNG lưu công nợ; báo kế toán duyệt chứng từ ----------
create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ma_cn text := trim(coalesce(p_payload->>'maCN','')); v_qty numeric; v_before debts; v_after debts;
begin
  v_actor := require_permission('receipt:update');
  if v_ma_cn = '' then raise exception 'Cần chọn Mã CN/ĐX cần nghiệm thu.'; end if;
  v_qty := parse_number(p_payload->>'slThucNhan');
  if v_qty is null then raise exception 'Cần nhập SL thực nhận (khối lượng nghiệm thu).'; end if;
  select * into v_before from debts where ma_cn = v_ma_cn;
  if v_before is null then raise exception 'Không tìm thấy mã công nợ %.', v_ma_cn; end if;
  update debts set
    sl_thuc_nhan = v_qty,
    ngay_nhan = coalesce((p_payload->>'ngayNhan')::date, current_date),
    ma_chung_tu = coalesce(nullif(trim(coalesce(p_payload->>'chungTu','')),''), ma_chung_tu),
    han_thanh_toan = coalesce((p_payload->>'hanThanhToan')::date, han_thanh_toan),
    chung_tu_types = coalesce(p_payload->'chungTuTypes', '[]'::jsonb),
    nghiem_thu_files = coalesce(p_payload->'files', nghiem_thu_files),
    ho_so_day_du = (jsonb_array_length(coalesce(p_payload->'chungTuTypes','[]'::jsonb)) > 0),
    cho_bo_sung = false, ly_do_bo_sung = null,
    nghiem_thu_at = now(), nghiem_thu_by = v_actor.id,
    ghi_chu = case when coalesce(trim(p_payload->>'ghiChu'),'') <> '' then coalesce(ghi_chu||' | ','') || 'Nghiệm thu: ' || (p_payload->>'ghiChu') else ghi_chu end
  where id = v_before.id returning * into v_after;

  -- Báo kế toán có đơn chờ duyệt chứng từ.
  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'receipt_review', 'Đơn chờ duyệt chứng từ & lưu công nợ',
         v_ma_cn || ' — ' || coalesce(v_after.ten_doi_tuong,''), 'congnoconfirm', v_ma_cn
  from profiles where role in ('KeToanCongNo','Admin') and status = 'Hoạt động';

  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', 'Chờ kế toán duyệt chứng từ.');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end; $$;

-- ---- Kế toán: danh sách đơn đã nghiệm thu, chờ duyệt chứng từ ----------------
create or replace function rpc_get_receipt_review(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('congno:confirm');
  select coalesce(jsonb_agg(x order by (x->>'ngayNhan') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maCN', d.ma_cn, 'maDeXuat', p.ma_de_xuat, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', d.ten_doi_tuong,
      'boPhan', p.bo_phan, 'nguoiDeNghi', p.nguoi_de_nghi,
      'matHang', d.mat_hang, 'dvt', (select dvt from materials m where m.id = d.material_id),
      'slDat', d.sl_dat, 'slThucNhan', d.sl_thuc_nhan, 'donGia', d.don_gia, 'vatRate', d.vat_rate,
      'thanhTienThucNhan', round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
      'daThanhToan', d.da_thanh_toan, 'hanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD'),
      'ngayNhan', to_char(d.ngay_nhan,'YYYY-MM-DD'), 'dieuKhoanTT', d.dieu_khoan_tt,
      'chungTuTypes', coalesce(d.chung_tu_types,'[]'::jsonb),
      'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb), 'baoGia', coalesce(p.attachments,'[]'::jsonb)
    ) as x
    from debts d
    left join proposals p on p.id = d.proposal_id
    left join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false and d.sl_thuc_nhan is not null
      and d.cong_no_confirmed = false and not d.prepay and d.cho_bo_sung = false
    order by d.ngay_nhan desc nulls last
    limit least(greatest(coalesce(p_limit,200),1),500)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- ---- Kế toán: LƯU VỀ CÔNG NỢ (kèm số đã trả trước nếu có) --------------------
create or replace function rpc_confirm_cong_no(p_ma_cn text, p_da_thanh_toan numeric default 0) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_d debts;
begin
  v_actor := require_permission('congno:confirm');
  select * into v_d from debts where ma_cn = trim(coalesce(p_ma_cn,''));
  if v_d is null then raise exception 'Không tìm thấy khoản %.', p_ma_cn; end if;
  if v_d.sl_thuc_nhan is null then raise exception 'Đơn chưa nghiệm thu (chưa có SL thực nhận).'; end if;
  update debts set
    cong_no_confirmed = true, cong_no_confirmed_at = now(), cong_no_confirmed_by = v_actor.id,
    da_thanh_toan = greatest(coalesce(p_da_thanh_toan, 0), 0), cho_bo_sung = false, ly_do_bo_sung = null
  where id = v_d.id;
  perform write_audit(v_actor, 'CONFIRM_CONGNO', 'debts', v_d.ma_cn, to_jsonb(v_d), jsonb_build_object('daTraTruoc', p_da_thanh_toan), 'OK', 'Đã lưu về công nợ.');
  return jsonb_build_object('ok', true, 'maCN', v_d.ma_cn);
end; $$;

-- ---- Kế toán: TRẢ LẠI NVMH bổ sung chứng từ ---------------------------------
create or replace function rpc_return_receipt(p_ma_cn text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_d debts; v_reason text := nullif(trim(coalesce(p_reason,'')),''); v_creator uuid;
begin
  v_actor := require_permission('congno:confirm');
  if v_reason is null then raise exception 'Cần nhập lý do để NVMH bổ sung.'; end if;
  select * into v_d from debts where ma_cn = trim(coalesce(p_ma_cn,''));
  if v_d is null then raise exception 'Không tìm thấy khoản %.', p_ma_cn; end if;
  update debts set cho_bo_sung = true, ly_do_bo_sung = v_reason where id = v_d.id;
  select nguoi_tao into v_creator from proposals where id = v_d.proposal_id;
  if v_creator is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (v_creator, 'receipt_return', 'Cần bổ sung chứng từ nghiệm thu',
            v_d.ma_cn || ' bị ' || coalesce(v_actor.name,'kế toán') || ' trả lại: ' || v_reason, 'receipt', v_d.ma_cn);
  end if;
  perform write_audit(v_actor, 'RETURN_RECEIPT', 'debts', v_d.ma_cn, to_jsonb(v_d), jsonb_build_object('reason', v_reason), 'OK', v_reason);
  return jsonb_build_object('ok', true, 'maCN', v_d.ma_cn);
end; $$;

-- ---- Chỉ khoản đã lưu công nợ (hoặc trả trước) mới vào màn thanh toán --------
create or replace function rpc_list_open_debts(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),''); v_rows jsonb;
begin
  perform require_permission('payment:create');
  select coalesce(jsonb_agg(x order by (x->>'hanThanhToan') nulls last), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maCN', vd.ma_cn, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', vd.ten_doi_tuong, 'matHang', vd.mat_hang,
      'dvt', (select dvt from materials m where m.id = vd.material_id),
      'slDat', vd.sl_dat, 'slThucNhan', vd.sl_thuc_nhan, 'donGia', vd.don_gia, 'vatRate', vd.vat_rate,
      'thanhTienDat', vd.thanh_tien_dat, 'dieuKhoanTT', vd.dieu_khoan_tt,
      'maDeXuat', (select ma_de_xuat from proposals p where p.id = vd.proposal_id),
      'nguoiDeNghi', (select nguoi_de_nghi from proposals p where p.id = vd.proposal_id),
      'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', vd.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
      'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'trangThai', vd.trang_thai_dong
    ) as x
    from v_debts vd join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false and vd.so_tien_con_lai > 0 and vd.la_cong_no
      and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

create or replace function rpc_get_payable_debts(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),''); v_rows jsonb;
begin
  perform require_permission('payment:request');
  select coalesce(jsonb_agg(x order by (x->>'hanThanhToan') nulls first), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'debtId', vd.id, 'maCN', vd.ma_cn, 'maDoiTuong', dt.ma_doi_tuong, 'tenDoiTuong', vd.ten_doi_tuong,
      'matHang', vd.mat_hang, 'hanThanhToan', to_char(vd.han_thanh_toan, 'YYYY-MM-DD'), 'ngayDuyet', to_char(vd.ngay_duyet, 'YYYY-MM-DD'),
      'soDuConLai', vd.so_tien_con_lai, 'dieuKhoanTT', vd.dieu_khoan_tt, 'hoSoDayDu', vd.ho_so_day_du,
      'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb), 'baoGia', coalesce(p.attachments,'[]'::jsonb)
    ) as x
    from v_debts vd
    join doi_tuong dt on dt.id = vd.doi_tuong_id
    join debts d on d.id = vd.id
    left join proposals p on p.id = d.proposal_id
    where vd.is_archived = false and vd.so_tien_con_lai > 0 and vd.la_cong_no
      and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- ---- Danh sách nghiệm thu của NVMH: khoản chờ nghiệm thu + khoản bị trả lại --
create or replace function rpc_get_open_receipt_items(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('receipt:update');
  select coalesce(jsonb_agg(row_data order by (row_data->>'ChoBoSung') desc, (row_data->>'NgayDuyet') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'MaCN', d.ma_cn, 'MaDeXuat', p.ma_de_xuat, 'MaDoiTuong', dt.ma_doi_tuong, 'TenDoiTuong', d.ten_doi_tuong,
      'MatHang', d.mat_hang, 'dvt', (select dvt from materials m where m.id = d.material_id),
      'SLDat', d.sl_dat, 'SLThucNhan', d.sl_thuc_nhan, 'DonGia', d.don_gia, 'VATRate', d.vat_rate,
      'ThanhTienDat', round(coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate), 2),
      'NguoiDeNghi', p.nguoi_de_nghi, 'DieuKhoanTT', d.dieu_khoan_tt,
      'HanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD'), 'Attachments', coalesce(p.attachments,'[]'::jsonb),
      'ChungTuTypes', coalesce(d.chung_tu_types,'[]'::jsonb),
      'ChoBoSung', d.cho_bo_sung, 'LyDoBoSung', d.ly_do_bo_sung,
      'NgayDuyet', to_char(d.ngay_duyet, 'YYYY-MM-DD')
    ) as row_data
    from debts d
    left join proposals p on p.id = d.proposal_id
    left join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false and (d.sl_thuc_nhan is null or d.cho_bo_sung = true)
    order by d.created_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

grant execute on function rpc_update_receipt(jsonb) to authenticated;
grant execute on function rpc_get_open_receipt_items(int) to authenticated;
grant execute on function rpc_get_receipt_review(int) to authenticated;
grant execute on function rpc_confirm_cong_no(text, numeric) to authenticated;
grant execute on function rpc_return_receipt(text, text) to authenticated;
grant execute on function rpc_list_open_debts(text) to authenticated;
grant execute on function rpc_get_payable_debts(text) to authenticated;


-- ---- Dashboard công nợ: chỉ tính khoản đã lưu công nợ (Đợt E) --------------
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
      and vd.la_cong_no   -- chỉ khoản đã lưu công nợ (hoặc trả trước)
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
grant execute on function rpc_get_debt_dashboard(jsonb) to authenticated;
