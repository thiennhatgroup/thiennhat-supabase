-- ============================================================================
-- dummy_ktth_test.sql — DỮ LIỆU DUMMY để KẾ TOÁN (KTTH) kiểm thử.
-- CÁCH DÙNG: mở Supabase → SQL Editor → dán TOÀN BỘ file này → Run.
--   Chạy-một-phát: tự XÓA dummy cũ, tự NẠP mới, cuối cùng HIỆN bảng đếm.
--   (An toàn chạy lại nhiều lần — không cần sửa/bỏ comment gì.)
-- 4 bộ phận: Sản xuất · Kế hoạch-Vật tư · Sửa chữa máy móc · Văn phòng.
-- Mỗi bộ phận có 4 giai đoạn để KTTH thao tác đủ các bước:
--   (1) Đã nghiệm thu, CHỜ DUYỆT HỒ SƠ  -> màn "Duyệt hồ sơ thanh toán"
--   (2) Đã lưu công nợ                   -> màn "Đề xuất thanh toán" / "Theo dõi công nợ"
--   (3) ĐXTT CHỜ Chủ tịch duyệt          -> màn "Duyệt đề xuất thanh toán"
--   (4) ĐXTT ĐÃ duyệt (chờ thủ quỹ chi)  -> màn "Chi tiền" / "Theo dõi"
-- ============================================================================

-- ---- BƯỚC 1: XÓA dummy cũ (an toàn nếu chưa có) -----------------------------
delete from payment_request_lines where request_id in (select id from payment_requests where ma_de_xuat_tt like 'PTK-DUMMYK-%');
delete from payment_requests where ma_de_xuat_tt like 'PTK-DUMMYK-%';
delete from payment_allocations where ma_cn like 'CNK-DUMMYK-%';
delete from payments where ma_cn like 'CNK-DUMMYK-%';
update proposal_lines set debt_id = null where ma_line like 'DXLK-DUMMYK-%';
delete from debts where ma_cn like 'CNK-DUMMYK-%';
delete from proposal_lines where ma_line like 'DXLK-DUMMYK-%';
delete from proposals where ma_de_xuat like 'DXK-DUMMYK-%';
delete from doi_tuong where ma_doi_tuong like 'DTK-DUMMYK-%';

-- ---- BƯỚC 2: NẠP dummy ------------------------------------------------------
do $$
declare
  v_buyer uuid; v_ktth uuid;
  v_depts text[] := array['Sản xuất','Kế hoạch-Vật tư','Sửa chữa máy móc','Văn phòng'];
  v_dept text; di int; st int; j int;
  v_dt uuid; v_pid uuid; v_debt uuid; v_req uuid;
  v_seq int := 0; v_reqseq int := 0;
  v_qty numeric := 20; v_price numeric; v_han date; v_tt numeric;
  v_cnf boolean; v_s3 uuid[]; v_s4 uuid[];
  v_mats text[] := array['Thép tấm','Dầu thủy lực','Vòng bi','Giấy A4','Que hàn','Băng keo'];
  v_mat text;
begin
  select id into v_buyer from profiles where email = 'ahuyle.work@gmail.com';
  if v_buyer is null then select id into v_buyer from profiles order by created_at limit 1; end if;
  if v_buyer is null then raise exception 'Chưa có tài khoản (profiles) — hãy tạo tài khoản trước.'; end if;
  -- ĐXTT gắn cho tài khoản Kế toán công nợ (nếu có) để KTTH thấy trong "Đề xuất của tôi".
  select id into v_ktth from profiles where role = 'KeToanCongNo' and status = 'Hoạt động' order by created_at limit 1;
  v_ktth := coalesce(v_ktth, v_buyer);

  for di in 1..array_length(v_depts,1) loop
    v_dept := v_depts[di];
    insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, so_tk_ngan_hang, chi_nhanh_ngan_hang, dieu_khoan_tt_mac_dinh, bo_phan, trang_thai)
    values ('DTK-DUMMYK-' || di, 'NCC ' || v_dept || ' (DUMMY)', 'NCC', '010000000' || di,
            '112233445' || di, 'Vietcombank CN Test', 'Thanh toán sau khi nhận hàng', v_dept, 'Hoạt động')
    returning id into v_dt;

    v_s3 := array[]::uuid[]; v_s4 := array[]::uuid[];
    for st in 1..8 loop        -- 1-2: gđ1; 3-4: gđ2; 5-6: gđ3; 7-8: gđ4
      v_seq := v_seq + 1;
      v_mat := v_mats[1 + (v_seq % array_length(v_mats,1))];
      v_price := case when st % 2 = 1 then 300000 else 2500000 end;
      v_han := current_date + (st * 3);
      v_tt := round(v_qty * v_price * 1.08, 2);
      v_cnf := (st >= 3);

      insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, doi_tuong_id, ten_doi_tuong,
        noi_dung, dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan,
        han_thanh_toan, truong_bp_duyet, attachments, approved_at, nguoi_duyet)
      values ('DXK-DUMMYK-' || lpad(v_seq::text,4,'0'), current_date - 5, 'NV ' || v_dept,
        v_dept, v_dt, 'NCC ' || v_dept || ' (DUMMY)',
        'Đơn dummy ' || v_dept || ' #' || st, 'Thanh toán sau khi nhận hàng', 'Đã duyệt', v_buyer, 'DUMMYK',
        'MuaHang', true, v_han, true,
        '[{"name":"bao_gia_mau.pdf","url":"https://example.com/bao_gia_dummy.pdf"}]'::jsonb,
        now() - interval '2 hours', v_buyer)
      returning id into v_pid;

      insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
      values ('DXLK-DUMMYK-' || lpad(v_seq::text,4,'0'), v_pid, v_mat, v_qty, v_price, 0.08, v_tt, 'DUMMYK', 'Đã duyệt');

      insert into debts (ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no, proposal_id,
        ma_lo_hang, mat_hang, sl_dat, sl_thuc_nhan, don_gia, vat_rate, dieu_khoan_tt, han_thanh_toan,
        nghiem_thu_files, ho_so_day_du, chung_tu_types, cong_no_confirmed, cong_no_confirmed_at, cong_no_confirmed_by,
        cho_bo_sung, ghi_chu, nguon_tao)
      values ('CNK-DUMMYK-' || lpad(v_seq::text,4,'0'), current_date - 5, current_date - 4,
        v_dt, 'NCC ' || v_dept || ' (DUMMY)', 'AP', v_pid, 'DXK-DUMMYK-' || lpad(v_seq::text,4,'0') || '-01',
        v_mat, v_qty, v_qty, v_price, 0.08, 'Thanh toán sau khi nhận hàng', v_han,
        '[{"name":"bien_ban_giao_nhan.pdf","url":"https://example.com/bbgn_dummy.pdf"}]'::jsonb,
        true, '["Hóa đơn VAT","Biên bản giao nhận / nghiệm thu"]'::jsonb,
        v_cnf, case when v_cnf then now() - interval '1 hour' else null end, case when v_cnf then v_buyer else null end,
        false, 'DUMMYK', 'WebApp')
      returning id into v_debt;

      update proposal_lines set debt_id = v_debt where proposal_id = v_pid;
      if st in (5,6) then v_s3 := array_append(v_s3, v_debt); end if;
      if st in (7,8) then v_s4 := array_append(v_s4, v_debt); end if;
    end loop;

    -- Giai đoạn 3: ĐXTT CHỜ Chủ tịch duyệt
    v_reqseq := v_reqseq + 1;
    insert into payment_requests (ma_de_xuat_tt, ngay, nguoi_lap, trang_thai, ghi_chu)
    values ('PTK-DUMMYK-' || lpad(v_reqseq::text,3,'0'), current_date, v_buyer, 'Chờ duyệt', 'DUMMYK ' || v_dept)
    returning id into v_req;
    for j in 1..array_length(v_s3,1) loop
      insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so)
      select v_req, d.id, d.doi_tuong_id, d.ten_doi_tuong,
             round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
             round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
             'Thanh toán ' || d.ma_cn, 'CK', 'Đã có hồ sơ'
      from debts d where d.id = v_s3[j];
    end loop;

    -- Giai đoạn 4: ĐXTT ĐÃ duyệt (chờ thủ quỹ chi)
    v_reqseq := v_reqseq + 1;
    insert into payment_requests (ma_de_xuat_tt, ngay, nguoi_lap, trang_thai, ghi_chu, nguoi_duyet, approved_at)
    values ('PTK-DUMMYK-' || lpad(v_reqseq::text,3,'0'), current_date, v_buyer, 'Đã duyệt', 'DUMMYK ' || v_dept, v_buyer, now() - interval '30 minutes')
    returning id into v_req;
    for j in 1..array_length(v_s4,1) loop
      insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so)
      select v_req, d.id, d.doi_tuong_id, d.ten_doi_tuong,
             round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
             round(d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate), 2),
             'Thanh toán ' || d.ma_cn, 'CK', 'Đã có hồ sơ'
      from debts d where d.id = v_s4[j];
    end loop;
  end loop;
end $$;

-- ---- BƯỚC 3: KIỂM TRA (bảng này hiện ra là đã nạp thành công) --------------
select 'Đơn (đã duyệt/nghiệm thu)' as muc, count(*) as so_luong from proposals where ma_de_xuat like 'DXK-DUMMYK-%'
union all select '  → Chờ KTTH duyệt hồ sơ', count(*) from debts where ma_cn like 'CNK-DUMMYK-%' and cong_no_confirmed = false
union all select '  → Đã lưu công nợ',       count(*) from debts where ma_cn like 'CNK-DUMMYK-%' and cong_no_confirmed = true
union all select 'ĐXTT chờ Chủ tịch duyệt',  count(*) from payment_requests where ma_de_xuat_tt like 'PTK-DUMMYK-%' and trang_thai = 'Chờ duyệt'
union all select 'ĐXTT đã duyệt (chờ thủ quỹ)', count(*) from payment_requests where ma_de_xuat_tt like 'PTK-DUMMYK-%' and trang_thai = 'Đã duyệt';
