-- ============================================================================
-- ap_flow_simulation.sql - MO PHONG TOAN BO LUONG NGHIEP VU CONG NO
--
-- Cach chay: mo Supabase -> SQL Editor -> dan TOAN BO file nay -> Run.
--   * Script boc trong 1 transaction va KET THUC BANG ROLLBACK
--     => KHONG de lai bat ky du lieu nao trong DB.
--   * Gia lap 1 tai khoan that trong profiles bang request.jwt.claims, sau do
--     doi role trong transaction de di qua cac buoc nhu NVMH / KTTH / lanh dao /
--     thu quy. ROLLBACK se hoan lai profile.
--   * Ket qua in ra la bang PASS/FAIL tung buoc (SELECT cuoi cung).
--
-- Kich ban:
--   A. Mua hang thuong theo luong hien tai:
--      tao -> duyet -> nghiem thu + chung tu -> KTTH luu cong no ->
--      lap DXTT -> duyet DXTT -> thu quy chi tung dong -> cap nhat so du.
--   B. Tra truoc (prepay): cong no hien ngay khi duyet theo SL dat.
--   C. Phan luong theo muc tien: >=10tr ma TGD duyet bi chan; ChuTich duyet OK.
--   D. Tra lai (bounce): go cong no da sinh, phieu ve Nhap + luu ly do.
-- ============================================================================

begin;

create temp table _r (
  id serial,
  buoc text,
  ky_vong text,
  thuc_te text,
  ket_qua text
) on commit drop;

create or replace function pg_temp.sim_note(
  p_buoc text,
  p_ky_vong text,
  p_thuc_te text,
  p_pass boolean
) returns void
language plpgsql as $$
begin
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (p_buoc, p_ky_vong, p_thuc_te, case when p_pass then 'PASS' else 'FAIL' end);
end;
$$;

create or replace function pg_temp.sim_use_role(
  p_actor uuid,
  p_dept_id uuid,
  p_role text
) returns void
language plpgsql as $$
begin
  update profiles
     set role = p_role,
         status = 'Hoạt động',
         department_id = p_dept_id,
         bo_phan = 'SIM'
   where id = p_actor;
end;
$$;

create or replace function pg_temp.sim_quote_files(p_tag text, p_suffix text) returns jsonb
language plpgsql as $$
begin
  return jsonb_build_array(jsonb_build_object(
    'name', 'bao-gia-' || p_tag || '.pdf',
    'bucket', 'attachments',
    'path', 'bao-gia/sim/' || p_tag || '-' || p_suffix || '.pdf',
    'size', 1024,
    'type', 'application/pdf',
    'ext', 'pdf'
  ));
end;
$$;

create or replace function pg_temp.sim_receipt_files(p_tag text, p_suffix text) returns jsonb
language plpgsql as $$
begin
  return jsonb_build_array(
    jsonb_build_object(
      'name', 'vat-' || p_tag || '.pdf',
      'bucket', 'attachments',
      'path', 'nghiem-thu/vat/' || p_tag || '-' || p_suffix || '.pdf',
      'size', 1024,
      'type', 'application/pdf',
      'ext', 'pdf'
    ),
    jsonb_build_object(
      'name', 'bbgn-' || p_tag || '.pdf',
      'bucket', 'attachments',
      'path', 'nghiem-thu/chung-tu/' || p_tag || '-' || p_suffix || '.pdf',
      'size', 1024,
      'type', 'application/pdf',
      'ext', 'pdf'
    )
  );
end;
$$;

create or replace function pg_temp.sim_payment_files(p_tag text, p_suffix text) returns jsonb
language plpgsql as $$
begin
  return jsonb_build_array(jsonb_build_object(
    'name', 'unc-' || p_tag || '.pdf',
    'bucket', 'attachments',
    'path', 'chi-tien/sim/' || p_tag || '-' || p_suffix || '.pdf',
    'size', 1024,
    'type', 'application/pdf',
    'ext', 'pdf'
  ));
end;
$$;

do $sim$
declare
  v jsonb;
  v_ma text;
  v_cn text;
  v_pr text;
  v_dt_ma text;
  v_line_id uuid;
  v_d record;
  v_actor uuid;
  v_dept_id uuid;
  v_cnt int;
  v_err text;
  v_ok boolean;
  v_quote jsonb;
  v_receipt_files jsonb;
  v_payment_proof_1 jsonb;
  v_payment_proof_2 jsonb;
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
begin
  select id
    into v_actor
  from profiles
  where status = 'Hoạt động'
  order by case when role = 'Admin' then 0 else 1 end, created_at
  limit 1;

  if v_actor is null then
    perform pg_temp.sim_note(
      'PRE. Tim tai khoan gia lap',
      'co it nhat 1 profile Hoạt động',
      'khong co profile Hoạt động de gia lap',
      false
    );
    return;
  end if;

  select app_ensure_department_id('SIM') into v_dept_id;
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor)::text, true);
  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'NhanVienMuaHang');

  -- =====================================================================
  -- KICH BAN A - MUA HANG THUONG (10 x 1.000.000, VAT 8% = 10.800.000)
  -- Nghiem thu 8/10 => 8.640.000. Chi 5.000.000, sau do chi phan con lai.
  -- =====================================================================
  v_quote := pg_temp.sim_quote_files('a', v_suffix);
  v_receipt_files := pg_temp.sim_receipt_files('a', v_suffix);
  v_payment_proof_1 := pg_temp.sim_payment_files('a-dot-1', v_suffix);
  v_payment_proof_2 := pg_temp.sim_payment_files('a-dot-2', v_suffix);

  v := rpc_create_proposal(jsonb_build_object(
    'status', 'Chờ duyệt',
    'loaiDeXuat', 'MuaHang',
    'trongKeHoachTuan', true,
    'ngayDeXuat', current_date::text,
    'nguoiDeNghi', 'SIM Tester',
    'boPhan', 'SIM',
    'hanThanhToan', (current_date + 30)::text,
    'doiTuong', jsonb_build_object('ten', 'SIM NCC A', 'loai', 'NCC'),
    'dieuKhoanTT', 'NET30',
    'attachments', v_quote,
    'lines', jsonb_build_array(jsonb_build_object(
      'matHang', 'SIM Vật tư A',
      'slDat', '10',
      'donGia', '1000000',
      'vat', '8%'
    ))
  ));
  v_ma := v->>'maDeXuat';
  perform pg_temp.sim_note('A1. Tao de xuat co bao gia', 'co ma de xuat', coalesce(v_ma, '(null)'), v_ma is not null);

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ChuTich');
  perform rpc_approve_proposal(v_ma, 'SIM duyet mua hang');
  select vd.* into v_d
  from v_debts vd
  join proposals p on p.id = vd.proposal_id
  where p.ma_de_xuat = v_ma
  limit 1;
  v_cn := v_d.ma_cn;
  select ma_doi_tuong into v_dt_ma from doi_tuong where id = v_d.doi_tuong_id;
  perform pg_temp.sim_note(
    'A2. Duyet de xuat sinh khoan cho nghiem thu',
    'dat=10.800.000, thuc nhan=0, chua phai cong no',
    format('dat=%s, thuc=%s, con=%s, la_cong_no=%s, tt=%s',
      v_d.thanh_tien_dat, v_d.thanh_tien_thuc_nhan, v_d.so_tien_con_lai, v_d.la_cong_no, v_d.trang_thai_dong),
    v_d.thanh_tien_dat = 10800000
      and v_d.thanh_tien_thuc_nhan = 0
      and v_d.so_tien_con_lai = 0
      and v_d.la_cong_no = false
      and v_d.trang_thai_dong = 'Chờ nghiệm thu'
  );

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'NhanVienMuaHang');
  perform rpc_update_receipt(jsonb_build_object(
    'maCN', v_cn,
    'slThucNhan', '8',
    'ngayNhan', current_date::text,
    'hanThanhToan', (current_date + 30)::text,
    'soTk', '0123456789',
    'chiNhanh', 'SIM Bank HCM',
    'soHoaDon', 'SIM-VAT-A-001',
    'chungTu', 'SIM-BBGN-A-001',
    'chungTuTypes', jsonb_build_array('vat', 'bbgn'),
    'files', v_receipt_files,
    'ghiChu', 'SIM nghiem thu du chung tu'
  ));
  select vd.* into v_d from v_debts vd where vd.ma_cn = v_cn;
  perform pg_temp.sim_note(
    'A3. NVMH nghiem thu kem VAT/BBGN',
    'thuc nhan=8.640.000, van chua vao cong no thanh toan',
    format('thuc=%s, con=%s, la_cong_no=%s, tt=%s',
      v_d.thanh_tien_thuc_nhan, v_d.so_tien_con_lai, v_d.la_cong_no, v_d.trang_thai_dong),
    v_d.thanh_tien_thuc_nhan = 8640000
      and v_d.so_tien_con_lai = 8640000
      and v_d.la_cong_no = false
      and v_d.trang_thai_dong = 'Chờ kế toán duyệt chứng từ'
  );

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'KeToanCongNo');
  perform rpc_confirm_cong_no(v_cn, 0);
  select vd.* into v_d from v_debts vd where vd.ma_cn = v_cn;
  perform pg_temp.sim_note(
    'A4. KTTH luu ve cong no',
    'la_cong_no=true, con phai tra=8.640.000',
    format('la_cong_no=%s, con=%s, can_settle=%s, tt=%s',
      v_d.la_cong_no, v_d.so_tien_con_lai, v_d.can_settle, v_d.trang_thai_dong),
    v_d.la_cong_no
      and v_d.so_tien_con_lai = 8640000
      and v_d.can_settle
  );

  v := rpc_create_payment_request(jsonb_build_object(
    'status', 'Chờ duyệt',
    'ngay', current_date::text,
    'ghiChu', 'SIM thanh toan dot 1',
    'lines', jsonb_build_array(jsonb_build_object(
      'debtId', v_d.id::text,
      'ncc', v_d.ten_doi_tuong,
      'keHoach', '5000000',
      'soTien', '5000000',
      'noiDung', 'Thanh toan dot 1 ' || v_cn,
      'hinhThucTT', 'CK',
      'tinhTrangHoSo', 'Du ho so'
    ))
  ));
  v_pr := v->>'maDeXuatTT';
  select prl.id into v_line_id
  from payment_requests pr
  join payment_request_lines prl on prl.request_id = pr.id
  where pr.ma_de_xuat_tt = v_pr
  limit 1;
  perform pg_temp.sim_note(
    'A5. KTTH lap DXTT dot 1',
    'DXTT Cho duyet co 1 dong noi voi cong no',
    format('ma=%s, line=%s', coalesce(v_pr, '(null)'), coalesce(v_line_id::text, '(null)')),
    v_pr is not null and v_line_id is not null
  );

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ChuTich');
  perform rpc_approve_payment_request(v_pr, 'SIM duyet DXTT dot 1');
  select trang_thai into v_err from payment_requests where ma_de_xuat_tt = v_pr;
  perform pg_temp.sim_note('A6. Lanh dao duyet DXTT dot 1', 'Đã duyệt', coalesce(v_err, '(null)'), v_err = 'Đã duyệt');

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ThuQuy');
  perform rpc_cashier_pay_line(v_line_id, v_payment_proof_1, 5000000, 'CK');
  select vd.* into v_d from v_debts vd where vd.ma_cn = v_cn;
  select pr.trang_thai || ' | paid=' || prl.paid || ' | paid_amount=' || coalesce(prl.so_tien_da_chuyen::text, '(null)')
    into v_err
  from payment_requests pr
  join payment_request_lines prl on prl.request_id = pr.id
  where pr.ma_de_xuat_tt = v_pr
  limit 1;
  perform pg_temp.sim_note(
    'A7. Thu quy chi dot 1 theo dong',
    'dong da chi, da tra=5.000.000, con=3.640.000',
    format('%s | da_tra=%s, con=%s', v_err, v_d.da_thanh_toan, v_d.so_tien_con_lai),
    v_d.da_thanh_toan = 5000000
      and v_d.so_tien_con_lai = 3640000
      and v_err like 'Đã chi | paid=true | paid_amount=5000000%'
  );

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'KeToanCongNo');
  v := rpc_create_payment_request(jsonb_build_object(
    'status', 'Chờ duyệt',
    'ngay', current_date::text,
    'ghiChu', 'SIM thanh toan phan con lai',
    'lines', jsonb_build_array(jsonb_build_object(
      'debtId', v_d.id::text,
      'ncc', v_d.ten_doi_tuong,
      'keHoach', '3640000',
      'soTien', '3640000',
      'noiDung', 'Thanh toan tat toan ' || v_cn,
      'hinhThucTT', 'Tiền mặt',
      'tinhTrangHoSo', 'Du ho so'
    ))
  ));
  v_pr := v->>'maDeXuatTT';
  select prl.id into v_line_id
  from payment_requests pr
  join payment_request_lines prl on prl.request_id = pr.id
  where pr.ma_de_xuat_tt = v_pr
  limit 1;

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ChuTich');
  perform rpc_approve_payment_request(v_pr, 'SIM duyet DXTT tat toan');

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ThuQuy');
  perform rpc_cashier_pay_line(v_line_id, v_payment_proof_2, 3640000, 'Tiền mặt');
  select vd.* into v_d from v_debts vd where vd.ma_cn = v_cn;
  select pr.trang_thai || ' | paid=' || prl.paid || ' | hinh_thuc=' || prl.hinh_thuc_tt
    into v_err
  from payment_requests pr
  join payment_request_lines prl on prl.request_id = pr.id
  where pr.ma_de_xuat_tt = v_pr
  limit 1;
  perform pg_temp.sim_note(
    'A8. Thu quy chi phan con lai',
    'con=0, trang thai cong no=Đã tất toán, DXTT=Đã chi',
    format('%s | da_tra=%s, con=%s, tt=%s', v_err, v_d.da_thanh_toan, v_d.so_tien_con_lai, v_d.trang_thai_dong),
    v_d.da_thanh_toan = 8640000
      and abs(v_d.so_tien_con_lai) < 1
      and v_d.trang_thai_dong = 'Đã tất toán'
      and v_err like 'Đã chi | paid=true | hinh_thuc=Tiền mặt%'
  );

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'KeToanCongNo');
  perform rpc_confirm_settlement(v_dt_ma);
  select * into v_d from debts where ma_cn = v_cn;
  perform pg_temp.sim_note(
    'A9. KTTH tat toan luu tru',
    'is_archived=true, da tra giu nguyen=8.640.000',
    format('archived=%s, da_tra=%s', v_d.is_archived, v_d.da_thanh_toan),
    v_d.is_archived and v_d.da_thanh_toan = 8640000
  );

  -- =====================================================================
  -- KICH BAN B - TRA TRUOC (prepay): cong no hien ngay khi duyet
  -- =====================================================================
  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'NhanVienMuaHang');
  v := rpc_create_proposal(jsonb_build_object(
    'status', 'Chờ duyệt',
    'loaiDeXuat', 'MuaHang',
    'trongKeHoachTuan', true,
    'prepay', true,
    'ngayDeXuat', current_date::text,
    'nguoiDeNghi', 'SIM Tester',
    'boPhan', 'SIM',
    'hanThanhToan', (current_date + 15)::text,
    'doiTuong', jsonb_build_object('ten', 'SIM NCC B', 'loai', 'NCC'),
    'attachments', pg_temp.sim_quote_files('b', v_suffix),
    'lines', jsonb_build_array(jsonb_build_object(
      'matHang', 'SIM Vật tư B',
      'slDat', '10',
      'donGia', '1000000',
      'vat', '8%'
    ))
  ));
  v_ma := v->>'maDeXuat';
  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ChuTich');
  perform rpc_approve_proposal(v_ma, 'SIM duyet prepay');
  select vd.* into v_d
  from v_debts vd
  join proposals p on p.id = vd.proposal_id
  where p.ma_de_xuat = v_ma
  limit 1;
  perform pg_temp.sim_note(
    'B1. Tra truoc duyet xong',
    'phai tra ngay=10.800.000 du chua nghiem thu',
    format('thuc=%s, con=%s, prepay=%s, tt=%s',
      v_d.thanh_tien_thuc_nhan, v_d.so_tien_con_lai, v_d.prepay, v_d.trang_thai_dong),
    v_d.thanh_tien_thuc_nhan = 10800000
      and v_d.so_tien_con_lai = 10800000
      and v_d.prepay
      and v_d.trang_thai_dong = 'Trả trước - chờ nhận hàng'
  );

  -- =====================================================================
  -- KICH BAN C - PHAN LUONG THEO MUC TIEN (nguong 10.000.000)
  -- 12.000.000 (12 x 1.000.000, VAT 0%)
  -- =====================================================================
  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'NhanVienMuaHang');
  v := rpc_create_proposal(jsonb_build_object(
    'status', 'Chờ duyệt',
    'loaiDeXuat', 'MuaHang',
    'trongKeHoachTuan', true,
    'ngayDeXuat', current_date::text,
    'nguoiDeNghi', 'SIM Tester',
    'boPhan', 'SIM',
    'hanThanhToan', (current_date + 30)::text,
    'doiTuong', jsonb_build_object('ten', 'SIM NCC C', 'loai', 'NCC'),
    'attachments', pg_temp.sim_quote_files('c', v_suffix),
    'lines', jsonb_build_array(jsonb_build_object(
      'matHang', 'SIM Vật tư C',
      'slDat', '12',
      'donGia', '1000000',
      'vat', '0%'
    ))
  ));
  v_ma := v->>'maDeXuat';

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'TongGiamDoc');
  v_ok := true;
  begin
    perform rpc_approve_proposal(v_ma, 'TGD thu duyet');
  exception when others then
    v_ok := false;
    v_err := sqlerrm;
  end;
  perform pg_temp.sim_note(
    'C1. TGD duyet >=10tr',
    'bi chan vi thuoc tham quyen Chu tich',
    case when v_ok then 'duyet lot (SAI)' else left(v_err, 100) end,
    not v_ok and v_err ilike '%TỊCH%'
  );

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ChuTich');
  perform rpc_approve_proposal(v_ma, 'Chu tich duyet');
  select trang_thai into v_err from proposals where ma_de_xuat = v_ma;
  perform pg_temp.sim_note('C2. Chu tich duyet >=10tr', 'Đã duyệt', coalesce(v_err, '(null)'), v_err = 'Đã duyệt');

  -- =====================================================================
  -- KICH BAN D - TRA LAI (bounce): go cong no, phieu ve Nhap + ly do
  -- =====================================================================
  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'NhanVienMuaHang');
  v := rpc_create_proposal(jsonb_build_object(
    'status', 'Chờ duyệt',
    'loaiDeXuat', 'MuaHang',
    'trongKeHoachTuan', true,
    'ngayDeXuat', current_date::text,
    'nguoiDeNghi', 'SIM Tester',
    'boPhan', 'SIM',
    'hanThanhToan', (current_date + 30)::text,
    'doiTuong', jsonb_build_object('ten', 'SIM NCC D', 'loai', 'NCC'),
    'attachments', pg_temp.sim_quote_files('d', v_suffix),
    'lines', jsonb_build_array(jsonb_build_object(
      'matHang', 'SIM Vật tư D',
      'slDat', '3',
      'donGia', '2000000',
      'vat', '8%'
    ))
  ));
  v_ma := v->>'maDeXuat';
  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'ChuTich');
  perform rpc_approve_proposal(v_ma, 'SIM duyet de test tra lai');

  perform pg_temp.sim_use_role(v_actor, v_dept_id, 'KeToanCongNo');
  perform rpc_bounce_proposal(v_ma, 'SIM: sai don gia, de nghi giai trinh');
  select count(*) into v_cnt
  from debts d
  join proposals p on p.id = d.proposal_id
  where p.ma_de_xuat = v_ma;
  select trang_thai || ' | ' || coalesce(ly_do_tra_lai, '(null)')
    into v_err
  from proposals
  where ma_de_xuat = v_ma;
  perform pg_temp.sim_note(
    'D1. Tra lai phieu da duyet',
    'cong no bi go (0), phieu=Nhap, co ly do',
    format('so cong no con=%s | %s', v_cnt, v_err),
    v_cnt = 0 and v_err like 'Nháp | SIM:%'
  );
end;
$sim$;

select
  buoc as "Bước",
  ky_vong as "Kỳ vọng",
  thuc_te as "Thực tế",
  ket_qua as "Kết quả"
from _r
order by id;

rollback;
