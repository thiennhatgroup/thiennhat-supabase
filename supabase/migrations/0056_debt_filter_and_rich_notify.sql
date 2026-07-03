-- ============================================================================
-- 0056_debt_filter_and_rich_notify.sql
--  (1) Bỏ khoản đã nằm trong một ĐỀ XUẤT THANH TOÁN đang "Chờ duyệt" hoặc
--      "Đã duyệt" (chưa đi tiền) ra khỏi danh sách chờ đề xuất TT. Trước đây,
--      duyệt phiếu TT chỉ đổi trạng thái, chưa trừ công nợ (chỉ khi "Đã chi"
--      mới trừ), nên khoản vẫn còn số dư -> hiện lại. Nay lọc theo phiếu TT.
--  (2) Làm giàu nội dung thông báo (web + push): ghi rõ nội dung/mặt hàng,
--      TỔNG TIỀN, và NGƯỜI ĐỀ NGHỊ/LẬP — áp dụng cho đề xuất mua hàng, đề
--      xuất thanh toán, và bước kế toán duyệt chứng từ.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- (1a) Khoản chờ đề xuất TT (màn tạo đề xuất thanh toán của kế toán)
-- ---------------------------------------------------------------------------
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
      and not exists (
        select 1 from payment_request_lines prl
        join payment_requests pr on pr.id = prl.request_id
        where prl.debt_id = vd.id and pr.trang_thai in ('Chờ duyệt','Đã duyệt')
      )
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- ---------------------------------------------------------------------------
-- (1b) Danh sách khoản còn phải trả (màn ghi nhận thanh toán / theo dõi)
-- ---------------------------------------------------------------------------
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
      'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'trangThai', vd.trang_thai_dong,
      'trongDeXuatTT', exists (
        select 1 from payment_request_lines prl
        join payment_requests pr on pr.id = prl.request_id
        where prl.debt_id = vd.id and pr.trang_thai in ('Chờ duyệt','Đã duyệt')
      )
    ) as x
    from v_debts vd join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false and vd.so_tien_con_lai > 0 and vd.la_cong_no
      and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

-- ---------------------------------------------------------------------------
-- (2a) Đề xuất mua hàng: thông báo cho lãnh đạo kèm bộ phận, số tiền, NGƯỜI ĐỀ NGHỊ
-- ---------------------------------------------------------------------------
create or replace function trg_proposals_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_total numeric; v_threshold numeric; v_nline int; v_msg text;
begin
  if (TG_OP = 'INSERT' and NEW.trang_thai = 'Chờ duyệt')
     or (TG_OP = 'UPDATE' and NEW.trang_thai = 'Chờ duyệt' and NEW.trang_thai is distinct from OLD.trang_thai) then
    select coalesce(sum(thanh_tien_sau_vat), 0), count(*) into v_total, v_nline from proposal_lines where proposal_id = NEW.id;
    select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';
    v_msg := NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong, '')
             || case when NEW.bo_phan is not null then ' · ' || NEW.bo_phan else '' end
             || ' · ' || v_nline || ' mặt hàng · ' || to_char(v_total, 'FM999,999,999') || 'đ'
             || case when coalesce(NEW.nguoi_de_nghi,'') <> '' then ' · Đề nghị: ' || NEW.nguoi_de_nghi else '' end;
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    select id, 'proposal_pending', 'Đề xuất mua hàng chờ duyệt', v_msg, 'approve', NEW.ma_de_xuat
    from profiles where role = 'ChuTich' and status = 'Hoạt động';
    if v_total < v_threshold then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'proposal_pending', 'Đề xuất mua hàng chờ duyệt', v_msg, 'approve', NEW.ma_de_xuat
      from profiles where role = 'TongGiamDoc' and status = 'Hoạt động';
    end if;
  elsif TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    if NEW.trang_thai = 'Đã duyệt' and NEW.nguoi_tao is not null then
      select coalesce(sum(thanh_tien_sau_vat), 0) into v_total from proposal_lines where proposal_id = NEW.id;
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_tao, 'proposal_approved', 'Đề xuất đã được duyệt',
              NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong,'') || ' · ' || to_char(v_total,'FM999,999,999') || 'đ · sẵn sàng nghiệm thu.',
              'receipt', NEW.ma_de_xuat);
    elsif NEW.trang_thai = 'Từ chối' and NEW.nguoi_tao is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_tao, 'proposal_rejected', 'Đề xuất bị từ chối / hủy duyệt',
              NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong,'') || ': ' || coalesce(NEW.ghi_chu, ''), 'proposal', NEW.ma_de_xuat);
    end if;
  end if;
  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- (2b) Đề xuất thanh toán: gửi thông báo "chờ duyệt" TỪ RPC (sau khi đã có dòng)
--      để kèm được TỔNG TIỀN + người lập. Trigger chỉ còn lo báo duyệt/từ chối.
-- ---------------------------------------------------------------------------
create or replace function trg_payreq_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_total numeric;
begin
  if TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    select coalesce(sum(so_tien),0) into v_total from payment_request_lines where request_id = NEW.id;
    if NEW.trang_thai = 'Đã duyệt' and NEW.nguoi_lap is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_lap, 'payreq_approved', 'Đề xuất thanh toán đã duyệt',
              NEW.ma_de_xuat_tt || ' · ' || to_char(v_total,'FM999,999,999') || 'đ — đã duyệt, có thể đi tiền.', 'payreq', NEW.ma_de_xuat_tt);
    elsif NEW.trang_thai = 'Từ chối' and NEW.nguoi_lap is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_lap, 'payreq_rejected', 'Đề xuất thanh toán bị từ chối',
              NEW.ma_de_xuat_tt || ' · ' || to_char(v_total,'FM999,999,999') || 'đ: ' || coalesce(NEW.ly_do_tu_choi,''), 'payreq', NEW.ma_de_xuat_tt);
    end if;
  end if;
  return NEW;
end;
$$;

-- Helper: báo Chủ tịch có 1 phiếu TT chờ duyệt (kèm tổng tiền + người lập).
create or replace function notify_payreq_pending_(p_request_id uuid, p_ma text, p_nguoi_lap text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_total numeric;
begin
  select coalesce(sum(so_tien),0) into v_total from payment_request_lines where request_id = p_request_id;
  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'payreq_pending', 'Đề xuất thanh toán chờ duyệt',
         p_ma || ' · ' || to_char(v_total,'FM999,999,999') || 'đ'
         || case when coalesce(p_nguoi_lap,'') <> '' then ' · Lập: ' || p_nguoi_lap else '' end,
         'payapprove', p_ma
  from profiles where role = 'ChuTich' and status = 'Hoạt động';
end; $$;

-- rpc_create_payment_request: như cũ + gọi notify_payreq_pending_ khi Chờ duyệt.
create or replace function rpc_create_payment_request(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_status text := case when coalesce(p_payload->>'status','Chờ duyệt') = 'Nháp' then 'Nháp' else 'Chờ duyệt' end;
  v_id uuid; v_ma text; v_line jsonb; v_debt debts; v_dt_id uuid; v_ncc text; v_sotien numeric; v_giaitrinh text; v_count int := 0;
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
    if v_sotien is null or v_sotien <= 0 then continue; end if;
    v_giaitrinh := nullif(trim(coalesce(v_line->>'giaiTrinh','')),'');
    v_dt_id := null; v_ncc := nullif(trim(coalesce(v_line->>'ncc','')),'');
    if nullif(v_line->>'debtId','') is not null then
      select * into v_debt from debts where id = (v_line->>'debtId')::uuid;
      if v_debt is not null then v_dt_id := v_debt.doi_tuong_id; v_ncc := coalesce(v_ncc, v_debt.ten_doi_tuong); end if;
    end if;
    if v_status = 'Chờ duyệt' and (v_line->>'debtId') is null and v_giaitrinh is null then
      raise exception 'Dòng "%" không nối khoản công nợ đã duyệt — cần nhập giải trình.', coalesce(v_ncc,'(chưa có NCC)');
    end if;
    if v_ncc is null then raise exception 'Mỗi dòng cần có tên nhà cung cấp.'; end if;
    insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so, giai_trinh)
    values (v_id, nullif(v_line->>'debtId','')::uuid, v_dt_id, v_ncc, coalesce(parse_number(v_line->>'keHoach'), 0), v_sotien, v_line->>'noiDung',
      case when coalesce(v_line->>'hinhThucTT','CK') = 'Tiền mặt' then 'Tiền mặt' else 'CK' end, v_line->>'tinhTrangHoSo', v_giaitrinh);
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'Đề xuất thanh toán cần ít nhất một dòng có số tiền hợp lệ.'; end if;
  if v_status = 'Chờ duyệt' then perform notify_payreq_pending_(v_id, v_ma, v_actor.name); end if;
  perform write_audit(v_actor, 'CREATE_PAYMENT_REQUEST', 'payment_requests', v_ma, null,
    jsonb_build_object('lines', v_count, 'status', v_status), 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuatTT', v_ma, 'status', v_status, 'lines', v_count);
end; $$;

-- rpc_update_payment_request: như cũ + gọi notify_payreq_pending_ khi gửi lại.
create or replace function rpc_update_payment_request(p_ma text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests;
  v_status text := case when coalesce(p_payload->>'status','Nháp') = 'Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_line jsonb; v_sotien numeric; v_ncc text; v_giaitrinh text; v_dt_id uuid; v_debt debts; v_count int := 0;
begin
  v_actor := require_permission('payment:request');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Nháp' then raise exception 'Chỉ sửa được phiếu đang Nháp.'; end if;
  update payment_requests set
    ngay = coalesce((p_payload->>'ngay')::date, ngay), ghi_chu = p_payload->>'ghiChu',
    trang_thai = v_status, ly_do_tra_lai = case when v_status = 'Chờ duyệt' then null else ly_do_tra_lai end
  where id = v_pr.id;
  delete from payment_request_lines where request_id = v_pr.id;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_sotien := parse_number(v_line->>'soTien');
    if v_sotien is null or v_sotien <= 0 then continue; end if;
    v_giaitrinh := nullif(trim(coalesce(v_line->>'giaiTrinh','')),'');
    v_ncc := nullif(trim(coalesce(v_line->>'ncc','')),''); v_dt_id := null;
    if nullif(v_line->>'debtId','') is not null then
      select * into v_debt from debts where id = (v_line->>'debtId')::uuid;
      if v_debt is not null then v_dt_id := v_debt.doi_tuong_id; v_ncc := coalesce(v_ncc, v_debt.ten_doi_tuong); end if;
    end if;
    if v_status = 'Chờ duyệt' and (v_line->>'debtId') is null and v_giaitrinh is null then
      raise exception 'Dòng "%" ngoài công nợ — cần giải trình.', coalesce(v_ncc,'(chưa có NCC)'); end if;
    if v_ncc is null then raise exception 'Mỗi dòng cần có tên nhà cung cấp.'; end if;
    insert into payment_request_lines (request_id, debt_id, doi_tuong_id, ncc, ke_hoach, so_tien, noi_dung, hinh_thuc_tt, tinh_trang_ho_so, giai_trinh)
    values (v_pr.id, nullif(v_line->>'debtId','')::uuid, v_dt_id, v_ncc, coalesce(parse_number(v_line->>'keHoach'),0), v_sotien, v_line->>'noiDung',
      case when coalesce(v_line->>'hinhThucTT','CK') = 'Tiền mặt' then 'Tiền mặt' else 'CK' end, v_line->>'tinhTrangHoSo', v_giaitrinh);
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'Đề xuất thanh toán cần ít nhất một dòng có số tiền.'; end if;
  if v_status = 'Chờ duyệt' then perform notify_payreq_pending_(v_pr.id, p_ma, v_actor.name); end if;
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma, 'status', v_status);
end; $$;

-- ---------------------------------------------------------------------------
-- (2c) Kế toán duyệt chứng từ: thông báo kèm mặt hàng, tổng tiền, người đề nghị
-- ---------------------------------------------------------------------------
create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ma_cn text := trim(coalesce(p_payload->>'maCN','')); v_qty numeric;
  v_before debts; v_after debts; v_nguoi text; v_tong numeric; v_msg text;
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

  select nguoi_de_nghi into v_nguoi from proposals where id = v_after.proposal_id;
  v_tong := round(coalesce(v_after.sl_thuc_nhan,0) * v_after.don_gia * (1 + v_after.vat_rate), 0);
  v_msg := v_ma_cn || ' — ' || coalesce(v_after.ten_doi_tuong,'')
           || case when coalesce(v_after.mat_hang,'') <> '' then ' · ' || v_after.mat_hang else '' end
           || ' · ' || to_char(v_tong,'FM999,999,999') || 'đ'
           || case when coalesce(v_nguoi,'') <> '' then ' · Đề nghị: ' || v_nguoi else '' end;

  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'receipt_review', 'Đơn chờ duyệt chứng từ & lưu công nợ', v_msg, 'congnoconfirm', v_ma_cn
  from profiles where role in ('KeToanCongNo','Admin') and status = 'Hoạt động';

  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', 'Chờ kế toán duyệt chứng từ.');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end; $$;

grant execute on function rpc_get_payable_debts(text) to authenticated;
grant execute on function rpc_list_open_debts(text) to authenticated;
grant execute on function rpc_create_payment_request(jsonb) to authenticated;
grant execute on function rpc_update_payment_request(text, jsonb) to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
