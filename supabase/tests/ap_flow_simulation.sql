-- ============================================================================
-- ap_flow_simulation.sql — MÔ PHỎNG TOÀN BỘ LUỒNG NGHIỆP VỤ CÔNG NỢ
--
-- Cách chạy: mở Supabase → SQL Editor → dán TOÀN BỘ file này → Run.
--   * Script bọc trong 1 transaction và KẾT THÚC BẰNG ROLLBACK
--     => KHÔNG để lại bất kỳ dữ liệu nào trong DB (an toàn với production).
--   * Giả lập actor = 1 tài khoản Admin (qua request.jwt.claims) để gọi
--     đúng các RPC thật y như khi bấm trên web.
--   * Kết quả in ra là bảng PASS/FAIL từng bước (SELECT cuối cùng).
--
-- Kịch bản:
--   A. Mua hàng thường: tạo → duyệt → nghiệm thu 1 phần → trả 1 phần →
--      HỦY khoản trả (undo) → trả đủ → tất toán (archive-only).
--   B. Trả trước (prepay): công nợ hiện NGAY khi duyệt theo SL đặt.
--   C. Phân luồng theo mức tiền: ≥10tr mà TGĐ duyệt -> bị chặn; ChuTich duyệt OK.
--   D. Trả lại (bounce): gỡ công nợ đã sinh, phiếu về Nháp + lưu lý do.
-- ============================================================================

begin;

-- Giả lập đăng nhập bằng 1 Admin đang hoạt động.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', (select id from profiles where role = 'Admin' and status = 'Hoạt động' order by created_at limit 1))::text,
  true
);

create temp table _r (id serial, buoc text, ky_vong text, thuc_te text, ket_qua text) on commit drop;

do $sim$
declare
  v jsonb; v_ma text; v_cn text; v_tt text; v_dt_ma text; v_d record; v_admin uuid;
  v_cnt int; v_err text;
  procedure_ok boolean;
begin
  select (current_setting('request.jwt.claims', true)::json->>'sub')::uuid into v_admin;

  -- =====================================================================
  -- KỊCH BẢN A — MUA HÀNG THƯỜNG (10 x 1.000.000, VAT 8% = 10.800.000)
  -- =====================================================================
  v := rpc_create_proposal(jsonb_build_object(
    'status','Chờ duyệt','loaiDeXuat','MuaHang','trongKeHoachTuan',true,
    'ngayDeXuat',current_date::text,'nguoiDeNghi','SIM Tester','boPhan','SIM',
    'hanThanhToan',(current_date + 30)::text,
    'doiTuong', jsonb_build_object('ten','SIM NCC A','loai','NCC'),
    'dieuKhoanTT','NET30',
    'lines', jsonb_build_array(jsonb_build_object('matHang','SIM Vật tư A','slDat','10','donGia','1000000','vat','8%'))
  ));
  v_ma := v->>'maDeXuat';
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A1. Tạo đề xuất (Chờ duyệt)','có mã', coalesce(v_ma,'(null)'), case when v_ma is not null then 'PASS' else 'FAIL' end);

  perform rpc_approve_proposal(v_ma, 'SIM duyệt');
  select vd.* into v_d from v_debts vd join proposals p on p.id=vd.proposal_id where p.ma_de_xuat=v_ma limit 1;
  v_cn := v_d.ma_cn;
  select ma_doi_tuong into v_dt_ma from doi_tuong where id = v_d.doi_tuong_id;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A2. Duyệt -> sinh công nợ','thành tiền đặt=10.800.000, chưa nghiệm thu -> phải trả=0',
     format('đặt=%s, thực nhận=%s, còn=%s, tt=%s', v_d.thanh_tien_dat, v_d.thanh_tien_thuc_nhan, v_d.so_tien_con_lai, v_d.trang_thai_dong),
     case when v_d.thanh_tien_dat=10800000 and v_d.thanh_tien_thuc_nhan=0 and v_d.so_tien_con_lai=0 and v_d.trang_thai_dong='Chờ nghiệm thu' then 'PASS' else 'FAIL' end);

  -- Nghiệm thu 8/10
  perform rpc_update_receipt(jsonb_build_object('maCN',v_cn,'slThucNhan','8','hanThanhToan',(current_date+30)::text));
  select vd.* into v_d from v_debts vd where vd.ma_cn=v_cn;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A3. Nghiệm thu 8/10','thực nhận=8.640.000, còn phải trả=8.640.000, can_settle=true',
     format('thực nhận=%s, còn=%s, can_settle=%s, tt=%s', v_d.thanh_tien_thuc_nhan, v_d.so_tien_con_lai, v_d.can_settle, v_d.trang_thai_dong),
     case when v_d.thanh_tien_thuc_nhan=8640000 and v_d.so_tien_con_lai=8640000 and v_d.can_settle then 'PASS' else 'FAIL' end);

  -- Trả 1 phần 5.000.000
  v := rpc_record_debt_payment(v_cn, 5000000, current_date, 'SIM-UNC-01', 'trả đợt 1');
  v_tt := v->>'maThanhToan';
  select vd.* into v_d from v_debts vd where vd.ma_cn=v_cn;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A4. Trả 1 phần 5.000.000','đã trả=5.000.000, còn=3.640.000',
     format('đã trả=%s, còn=%s', v_d.da_thanh_toan, v_d.so_tien_con_lai),
     case when v_d.da_thanh_toan=5000000 and v_d.so_tien_con_lai=3640000 then 'PASS' else 'FAIL' end);

  -- HỦY khoản trả (undo)
  perform rpc_delete_payment(v_tt);
  select vd.* into v_d from v_debts vd where vd.ma_cn=v_cn;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A5. Hủy khoản trả (undo)','đã trả về 0, còn=8.640.000, chưa lưu trữ',
     format('đã trả=%s, còn=%s, archived=%s', v_d.da_thanh_toan, v_d.so_tien_con_lai, v_d.is_archived),
     case when v_d.da_thanh_toan=0 and v_d.so_tien_con_lai=8640000 and not v_d.is_archived then 'PASS' else 'FAIL' end);

  -- Trả đủ 8.640.000
  perform rpc_record_debt_payment(v_cn, 8640000, current_date, 'SIM-UNC-02', 'trả đủ');
  select vd.* into v_d from v_debts vd where vd.ma_cn=v_cn;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A6. Trả đủ 8.640.000','còn=0, trạng thái=Đã tất toán',
     format('còn=%s, tt=%s', v_d.so_tien_con_lai, v_d.trang_thai_dong),
     case when v_d.so_tien_con_lai=0 and v_d.trang_thai_dong='Đã tất toán' then 'PASS' else 'FAIL' end);

  -- Tất toán = ARCHIVE-ONLY (không ghi đè đã trả)
  perform rpc_confirm_settlement(v_dt_ma);
  select * into v_d from debts where ma_cn=v_cn;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('A7. Tất toán (archive-only)','is_archived=true, đã trả GIỮ NGUYÊN=8.640.000',
     format('archived=%s, đã trả=%s', v_d.is_archived, v_d.da_thanh_toan),
     case when v_d.is_archived and v_d.da_thanh_toan=8640000 then 'PASS' else 'FAIL' end);

  -- =====================================================================
  -- KỊCH BẢN B — TRẢ TRƯỚC (prepay): công nợ hiện ngay khi duyệt
  -- =====================================================================
  v := rpc_create_proposal(jsonb_build_object(
    'status','Chờ duyệt','loaiDeXuat','MuaHang','trongKeHoachTuan',true,'prepay',true,
    'ngayDeXuat',current_date::text,'nguoiDeNghi','SIM Tester','boPhan','SIM',
    'hanThanhToan',(current_date + 15)::text,
    'doiTuong', jsonb_build_object('ten','SIM NCC B','loai','NCC'),
    'lines', jsonb_build_array(jsonb_build_object('matHang','SIM Vật tư B','slDat','10','donGia','1000000','vat','8%'))
  ));
  v_ma := v->>'maDeXuat';
  perform rpc_approve_proposal(v_ma, 'SIM duyệt prepay');
  select vd.* into v_d from v_debts vd join proposals p on p.id=vd.proposal_id where p.ma_de_xuat=v_ma limit 1;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('B1. Trả trước duyệt xong','phải trả NGAY=10.800.000 (dù chưa nghiệm thu), tt=Trả trước - chờ nhận hàng',
     format('thực nhận=%s, còn=%s, prepay=%s, tt=%s', v_d.thanh_tien_thuc_nhan, v_d.so_tien_con_lai, v_d.prepay, v_d.trang_thai_dong),
     case when v_d.thanh_tien_thuc_nhan=10800000 and v_d.so_tien_con_lai=10800000 and v_d.prepay and v_d.trang_thai_dong='Trả trước - chờ nhận hàng' then 'PASS' else 'FAIL' end);

  -- =====================================================================
  -- KỊCH BẢN C — PHÂN LUỒNG THEO MỨC TIỀN (ngưỡng 10.000.000)
  -- 12.000.000 (12 x 1.000.000, VAT 0%)
  -- =====================================================================
  v := rpc_create_proposal(jsonb_build_object(
    'status','Chờ duyệt','loaiDeXuat','MuaHang','trongKeHoachTuan',true,
    'ngayDeXuat',current_date::text,'nguoiDeNghi','SIM Tester','boPhan','SIM',
    'hanThanhToan',(current_date + 30)::text,
    'doiTuong', jsonb_build_object('ten','SIM NCC C','loai','NCC'),
    'lines', jsonb_build_array(jsonb_build_object('matHang','SIM Vật tư C','slDat','12','donGia','1000000','vat','0%'))
  ));
  v_ma := v->>'maDeXuat';

  -- (C1) TGĐ duyệt khoản ≥10tr -> phải bị chặn
  update profiles set role='TongGiamDoc' where id=v_admin;
  procedure_ok := true;
  begin
    perform rpc_approve_proposal(v_ma, 'TGĐ thử duyệt');
  exception when others then
    procedure_ok := false; v_err := sqlerrm;
  end;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('C1. TGĐ duyệt ≥10tr','BỊ CHẶN (thuộc thẩm quyền Chủ tịch)',
     case when procedure_ok then 'duyệt lọt (SAI)' else left(v_err,80) end,
     case when not procedure_ok and v_err ilike '%TỊCH%' then 'PASS' else 'FAIL' end);

  -- (C2) Chủ tịch duyệt -> OK
  update profiles set role='ChuTich' where id=v_admin;
  perform rpc_approve_proposal(v_ma, 'Chủ tịch duyệt');
  select trang_thai into v_err from proposals where ma_de_xuat=v_ma;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('C2. Chủ tịch duyệt ≥10tr','Đã duyệt', v_err,
     case when v_err='Đã duyệt' then 'PASS' else 'FAIL' end);
  update profiles set role='Admin' where id=v_admin;  -- khôi phục cho kịch bản D

  -- =====================================================================
  -- KỊCH BẢN D — TRẢ LẠI (bounce): gỡ công nợ, phiếu về Nháp + lý do
  -- =====================================================================
  v := rpc_create_proposal(jsonb_build_object(
    'status','Chờ duyệt','loaiDeXuat','MuaHang','trongKeHoachTuan',true,
    'ngayDeXuat',current_date::text,'nguoiDeNghi','SIM Tester','boPhan','SIM',
    'hanThanhToan',(current_date + 30)::text,
    'doiTuong', jsonb_build_object('ten','SIM NCC D','loai','NCC'),
    'lines', jsonb_build_array(jsonb_build_object('matHang','SIM Vật tư D','slDat','3','donGia','2000000','vat','8%'))
  ));
  v_ma := v->>'maDeXuat';
  perform rpc_approve_proposal(v_ma, 'SIM duyệt để test trả lại');
  select count(*) into v_cnt from debts d join proposals p on p.id=d.proposal_id where p.ma_de_xuat=v_ma;

  perform rpc_bounce_proposal(v_ma, 'SIM: sai đơn giá, đề nghị giải trình');
  select count(*) into v_cnt from debts d join proposals p on p.id=d.proposal_id where p.ma_de_xuat=v_ma;
  select trang_thai || ' | ' || coalesce(ly_do_tra_lai,'(null)') into v_err from proposals where ma_de_xuat=v_ma;
  insert into _r(buoc,ky_vong,thuc_te,ket_qua) values
    ('D1. Trả lại phiếu đã duyệt','công nợ bị gỡ (0), phiếu=Nháp, có lý do',
     format('số công nợ còn=%s | %s', v_cnt, v_err),
     case when v_cnt=0 and v_err like 'Nháp | SIM:%' then 'PASS' else 'FAIL' end);

end;
$sim$;

select buoc as "Bước", ky_vong as "Kỳ vọng", thuc_te as "Thực tế", ket_qua as "Kết quả"
from _r order by id;

rollback;
