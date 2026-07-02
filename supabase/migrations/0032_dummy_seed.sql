-- ============================================================================
-- 0032_dummy_seed.sql — DỮ LIỆU DUMMY để kiểm thử (~200 phiếu).
-- Mọi bản ghi được đánh dấu 'DUMMY' / mã có tiền tố *-DUMMY-* để dễ xóa.
-- Idempotent: chỉ chạy nếu chưa có phiếu dummy.
-- >>> XÓA DUMMY khi xong: chạy khối "CLEANUP" ở cuối file (đang comment).
-- ============================================================================

do $$
declare
  v_buyer uuid;
  v_dts uuid[]; v_dtnames text[]; v_mats text[];
  i int; v_status text; v_loai text; v_inplan boolean; v_han date;
  v_qty numeric; v_price numeric; v_pid uuid; v_debtid uuid; v_n int;
  v_acc int := 0;  -- đếm khoản đã nghiệm thu để tạo đề xuất TT
begin
  if exists (select 1 from proposals where ma_de_xuat like 'DX-DUMMY-%') then
    raise notice 'Dummy đã tồn tại, bỏ qua.'; return;
  end if;

  select id into v_buyer from profiles where email = 'ahuyle.work@gmail.com';
  if v_buyer is null then select id into v_buyer from profiles order by created_at limit 1; end if;
  if v_buyer is null then raise notice 'Chưa có profiles, bỏ qua dummy.'; return; end if;

  select array_agg(id), array_agg(ten_doi_tuong) into v_dts, v_dtnames
  from (select id, ten_doi_tuong from doi_tuong limit 12) s;
  select array_agg(ten) into v_mats from (select ten from materials limit 12) s;
  if v_dts is null or v_mats is null then raise notice 'Thiếu doi_tuong/materials, bỏ qua.'; return; end if;

  for i in 1..200 loop
    v_inplan := (i % 2 = 0);
    v_loai := case when i % 7 = 0 then 'TamUng' else 'MuaHang' end;
    v_han := current_date + (i % 30);
    v_qty := 10 + (i % 40);
    v_price := case when i % 2 = 0 then 50000 else 900000 end; -- tạo cả khoản <10tr và >=10tr
    v_status := case (i % 5) when 0 then 'Nháp' when 1 then 'Chờ duyệt' when 2 then 'Chờ duyệt' else 'Đã duyệt' end;

    insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, doi_tuong_id, ten_doi_tuong,
      noi_dung, dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan,
      giai_trinh_ngoai_ke_hoach, han_thanh_toan, ton_kho, truong_bp_duyet, attachments, approved_at, nguoi_duyet)
    values ('DX-DUMMY-' || lpad(i::text,4,'0'), current_date - (i % 20), 'NV Dummy ' || (1 + i % 6),
      'Bộ phận ' || (1 + i % 3), v_dts[1 + (i % array_length(v_dts,1))], v_dtnames[1 + (i % array_length(v_dtnames,1))],
      'Phiếu dummy #' || i, 'Thanh toán sau khi nhận hàng', v_status, v_buyer, 'DUMMY', v_loai, v_inplan,
      case when v_inplan then null else 'Giải trình phát sinh dummy #' || i end, v_han, (i % 100), (i % 3 = 0),
      '[{"name":"bao_gia_mau.pdf","url":"https://example.com/bao_gia_dummy.pdf"}]'::jsonb,
      case when v_status = 'Đã duyệt' then now() - ((i % 12) || ' hours')::interval else null end,
      case when v_status = 'Đã duyệt' then v_buyer else null end)
    returning id into v_pid;

    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values ('DXL-DUMMY-' || lpad(i::text,4,'0'), v_pid, v_mats[1 + (i % array_length(v_mats,1))], v_qty, v_price, 0.08,
      round(v_qty * v_price * 1.08, 2), 'DUMMY', case when v_status = 'Đã duyệt' then 'Đã duyệt' else v_status end);

    if v_status = 'Đã duyệt' then
      v_n := (i % 2 = 0)::int; -- một nửa phiếu đã duyệt sẽ được nghiệm thu
      insert into debts (ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no, proposal_id,
        ma_lo_hang, mat_hang, sl_dat, sl_thuc_nhan, don_gia, vat_rate, dieu_khoan_tt, han_thanh_toan,
        nghiem_thu_files, ho_so_day_du, ghi_chu, nguon_tao)
      values ('CN-DUMMY-' || lpad(i::text,4,'0'), current_date - (i % 20), current_date - (i % 10),
        v_dts[1 + (i % array_length(v_dts,1))], v_dtnames[1 + (i % array_length(v_dtnames,1))],
        case when v_loai = 'TamUng' then 'TamUng' else 'AP' end, v_pid, 'DX-DUMMY-' || lpad(i::text,4,'0') || '-01',
        v_mats[1 + (i % array_length(v_mats,1))], v_qty, case when v_n = 1 then v_qty else null end, v_price, 0.08,
        'Thanh toán sau khi nhận hàng', v_han,
        case when v_n = 1 then '[{"name":"bien_ban_mau.pdf","url":"https://example.com/bien_ban_dummy.pdf"}]'::jsonb else '[]'::jsonb end,
        (v_n = 1), 'DUMMY', 'WebApp')
      returning id into v_debtid;
      update proposal_lines set debt_id = v_debtid where proposal_id = v_pid;
      if v_n = 1 then v_acc := v_acc + 1; end if;
    end if;
  end loop;

  -- ~15 đề xuất thanh toán dummy từ các công nợ đã nghiệm thu còn số dư
  declare
    v_req uuid; v_d record; k int := 0;
  begin
    for v_d in
      select d.id, d.ma_cn, d.ten_doi_tuong, d.doi_tuong_id,
             round(coalesce(d.sl_thuc_nhan,0) * d.don_gia * (1 + d.vat_rate), 2) as so_du
      from debts d where d.ma_cn like 'CN-DUMMY-%' and d.sl_thuc_nhan is not null
      limit 15
    loop
      k := k + 1;
      insert into payment_requests (ma_de_xuat_tt, ngay, nguoi_lap, trang_thai, ghi_chu)
      values ('PT-DUMMY-' || lpad(k::text,3,'0'), current_date, v_buyer,
              case when k % 3 = 0 then 'Đã duyệt' else 'Chờ duyệt' end, 'DUMMY')
      returning id into v_req;
      insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so)
      values (v_req, v_d.id, v_d.doi_tuong_id, v_d.ten_doi_tuong, v_d.so_du, v_d.so_du, 'Thanh toán dummy ' || v_d.ma_cn, 'CK', 'Đã có hồ sơ');
    end loop;
  end;
  raise notice 'Đã tạo dummy: 200 phiếu, % khoản nghiệm thu.', v_acc;
end $$;

-- ============================================================================
-- CLEANUP — chạy khối dưới (bỏ comment) trong SQL Editor khi muốn xóa DUMMY:
-- delete from payment_request_lines where request_id in (select id from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%');
-- delete from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%';
-- delete from payment_allocations where ma_cn like 'CN-DUMMY-%';
-- delete from payments where ma_thanh_toan like 'TT-DUMMY-%';
-- update proposal_lines set debt_id = null where proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%');
-- delete from debts where ma_cn like 'CN-DUMMY-%';
-- delete from proposal_lines where ma_line like 'DXL-DUMMY-%';
-- delete from proposals where ma_de_xuat like 'DX-DUMMY-%';
-- delete from notifications where ref_id like '%DUMMY%';
-- ============================================================================
