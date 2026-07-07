-- ============================================================================
-- debt_detail_access.sql -- rollback-safe check for rpc_get_debt_detail access.
--
-- Cách chạy: mở Supabase -> SQL Editor -> dán toàn bộ file -> Run.
-- Script gọi RPC thật và kết thúc bằng ROLLBACK, không để lại dữ liệu.
-- ============================================================================

begin;

create temp table _r (
  id serial,
  buoc text,
  ky_vong text,
  thuc_te text,
  ket_qua text
) on commit drop;

do $test$
declare
  v_actor uuid;
  v_dt uuid;
  v_proposal uuid;
  v_request uuid;
  v jsonb;
  v_err text;
  v_ok boolean;
  v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_ma_dx text := 'DX-SIM-DETAIL-' || v_suffix;
  v_ma_cn text := 'CN-SIM-DETAIL-' || v_suffix;
  v_ma_doi_tuong text := 'DT-SIM-DETAIL-' || v_suffix;
  v_ma_dxtt text := 'DTT-SIM-DETAIL-' || v_suffix;
begin
  select id into v_actor
  from profiles
  order by created_at nulls last, id
  limit 1;

  if v_actor is null then
    insert into _r(buoc, ky_vong, thuc_te, ket_qua)
    values ('Chuẩn bị actor', 'Có ít nhất 1 profile để giả lập auth.uid()', 'Không có profile', 'SKIP');
    return;
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_actor::text)::text,
    true
  );

  update profiles
     set role = 'NhanVienMuaHang',
         status = 'Hoạt động'
   where id = v_actor;

  insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, so_tk_ngan_hang, chi_nhanh_ngan_hang)
  values (v_ma_doi_tuong, 'SIM NCC debt detail', 'NCC', 'SIM-MST', '123456789', 'SIM Bank')
  returning id into v_dt;

  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, doi_tuong_id, ten_doi_tuong, trang_thai, nguoi_tao, attachments)
  values (
    v_ma_dx,
    current_date,
    'SIM requester',
    v_dt,
    'SIM NCC debt detail',
    'Đã duyệt',
    null,
    jsonb_build_array(jsonb_build_object('name', 'bao-gia.pdf', 'path', 'sim/bao-gia.pdf'))
  )
  returning id into v_proposal;

  insert into debts (
    ma_cn,
    ngay_de_xuat,
    ngay_duyet,
    doi_tuong_id,
    ten_doi_tuong,
    proposal_id,
    mat_hang,
    sl_dat,
    sl_thuc_nhan,
    don_gia,
    vat_rate,
    ngay_nhan,
    han_thanh_toan,
    cong_no_confirmed,
    so_hoa_don_vat,
    chung_tu_types,
    nghiem_thu_files
  )
  values (
    v_ma_cn,
    current_date,
    current_date,
    v_dt,
    'SIM NCC debt detail',
    v_proposal,
    'SIM vật tư',
    2,
    2,
    100000,
    0.08,
    current_date,
    current_date + 10,
    true,
    'SIM-VAT-01',
    jsonb_build_array('VAT', 'BBGN'),
    jsonb_build_array(jsonb_build_object('name', 'vat.pdf', 'path', 'sim/vat.pdf'))
  );

  v_ok := true;
  v_err := null;
  begin
    perform rpc_get_debt_detail(v_ma_cn);
  exception when others then
    v_ok := false;
    v_err := sqlerrm;
  end;
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '1. NVMH không sở hữu khoản',
    'Bị chặn với lỗi quyền rõ ràng',
    case when v_ok then 'RPC trả dữ liệu' else v_err end,
    case when not v_ok and v_err ilike '%quyền xem chi tiết công nợ%' then 'PASS' else 'FAIL' end
  );

  update profiles set role = 'KeToanCongNo' where id = v_actor;
  v := rpc_get_debt_detail(v_ma_cn);
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '2. KTTH có debt:detail:read',
    'Xem được chi tiết và dữ liệu nhạy cảm cần cho hồ sơ',
    coalesce(v->'debt'->>'soTk', '(không có STK)'),
    case when v->>'ok' = 'true' and v->'debt'->>'soTk' = '123456789' then 'PASS' else 'FAIL' end
  );

  update profiles set role = 'NhanVienMuaHang' where id = v_actor;
  update proposals set nguoi_tao = v_actor where id = v_proposal;
  v := rpc_get_debt_detail(v_ma_cn);
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '3. NVMH sở hữu đề xuất',
    'Vẫn xem được khoản của mình',
    coalesce(v->'debt'->>'maCN', '(không có mã)'),
    case when v->'debt'->>'maCN' = v_ma_cn then 'PASS' else 'FAIL' end
  );

  update profiles set role = 'ThuQuy' where id = v_actor;
  update proposals set nguoi_tao = null where id = v_proposal;
  insert into payment_requests (ma_de_xuat_tt, ngay, nguoi_lap, trang_thai)
  values (v_ma_dxtt, current_date, v_actor, 'Đã duyệt')
  returning id into v_request;

  insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung)
  values (v_request, (select id from debts where ma_cn = v_ma_cn), v_dt, 'SIM NCC debt detail', 216000, 216000, 'SIM chi tiền');

  v := rpc_get_debt_detail(v_ma_cn);
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '4. Thủ quỹ có dòng ĐXTT đã duyệt',
    'Xem được chi tiết khoản cần chi',
    coalesce(v->'debt'->>'maCN', '(không có mã)'),
    case when v->'debt'->>'maCN' = v_ma_cn then 'PASS' else 'FAIL' end
  );
end;
$test$;

select buoc as "Bước", ky_vong as "Kỳ vọng", thuc_te as "Thực tế", ket_qua as "Kết quả"
from _r
order by id;

rollback;
