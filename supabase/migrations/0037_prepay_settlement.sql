-- ============================================================================
-- 0037_prepay_settlement.sql  (Đợt D)
--  * prepay: khoản "thanh toán trước khi nhận hàng" -> công nợ phải trả hiện
--    NGAY khi duyệt (theo SL đặt), không chờ nghiệm thu.
--  * v_debts: payable tính theo prepay.
--  * Tất toán ARCHIVE-ONLY: chỉ lưu trữ khoản đã trả đủ, KHÔNG ghi đè da_thanh_toan
--    (số dư = giá trị − Σ thanh toán đã ghi).
--  * Cấp quyền payment:create cho Nhân viên mua hàng (theo dõi/ghi thanh toán).
-- ============================================================================

alter table proposals add column if not exists prepay boolean not null default false;
alter table debts     add column if not exists prepay boolean not null default false;

insert into role_permissions (role, permission) values ('NhanVienMuaHang', 'payment:create')
on conflict (role, permission) do nothing;

-- ---- v_debts: payable xét prepay --------------------------------------------
-- drop trước vì thêm cột prepay vào d.* làm đổi thứ tự cột -> create or replace lỗi.
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
  case
    when (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
               when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan <= 0 then 0
    when d.han_thanh_toan is null then 0
    else greatest(0, (current_date - d.han_thanh_toan))
  end as so_ngay_qua_han,
  case
    when d.sl_thuc_nhan is null and not d.prepay and d.da_thanh_toan = 0 then 'Chờ nghiệm thu'
    when d.sl_thuc_nhan is null and d.prepay and d.da_thanh_toan = 0 then 'Trả trước - chờ nhận hàng'
    when (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
               when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan < 0 then 'Trả dư/đối trừ'
    when abs((case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
                   when d.prepay then coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan) < 1 then 'Đã tất toán'
    when d.han_thanh_toan is null then 'Cần nhập hạn TT'
    when greatest(0, (current_date - d.han_thanh_toan)) > 0 then 'Quá hạn'
    else 'Theo dõi'
  end as trang_thai_dong,
  ((d.sl_thuc_nhan is not null and (d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)) > 0)
    or (d.prepay and coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate) > 0)) as can_settle
from debts d;

-- ---- Tất toán: chỉ ARCHIVE khoản đã trả đủ, không ghi đè da_thanh_toan ------
create or replace function settlement_run_(p_actor profiles, p_ma_doi_tuong text, p_write boolean) returns jsonb
language plpgsql as $$
declare v_row record; v_preview jsonb := '[]'::jsonb; v_archived int := 0; v_kept int := 0;
begin
  for v_row in
    select d.ma_cn, d.ten_doi_tuong, vd.thanh_tien_thuc_nhan, vd.so_tien_con_lai, d.id
    from debts d join v_debts vd on vd.id = d.id
    join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false and vd.thanh_tien_thuc_nhan > 0
      and (p_ma_doi_tuong is null or dt.ma_doi_tuong = p_ma_doi_tuong)
  loop
    if v_row.so_tien_con_lai < 1 then
      v_preview := v_preview || jsonb_build_array(jsonb_build_object('action','archive','maCN',v_row.ma_cn,'doiTuong',v_row.ten_doi_tuong,'actual',v_row.thanh_tien_thuc_nhan,'conLai',v_row.so_tien_con_lai));
      v_archived := v_archived + 1;
      if p_write then update debts set is_archived = true, archived_at = now(), archived_by = p_actor.id where id = v_row.id; end if;
    else
      v_kept := v_kept + 1;
    end if;
  end loop;
  return jsonb_build_object('archived', v_archived, 'kept', v_kept, 'preview', v_preview);
end; $$;

-- ---- create/update/approve proposal: mang cờ prepay -------------------------
create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status','Nháp')='Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_loai text := case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end;
  v_in_plan boolean := coalesce((p_payload->>'trongKeHoachTuan')::boolean,false);
  v_giai_trinh text := nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),'');
  v_actor profiles; v_dt doi_tuong; v_ma text; v_pid uuid; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0; v_h jsonb;
begin
  v_actor := require_permission(case when v_status='Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines')=0 then raise exception 'Đề xuất cần ít nhất một dòng vật tư.'; end if;
  if v_status='Chờ duyệt' and not v_in_plan and v_giai_trinh is null then raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.'; end if;
  v_dt := ensure_doi_tuong(p_payload->'doiTuong'->>'ma', p_payload->'doiTuong'->>'ten', coalesce(p_payload->'doiTuong'->>'loai','NCC'),
    p_payload->'doiTuong'->>'mst', p_payload->'doiTuong'->>'diaChi', p_payload->'doiTuong'->>'contact', coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  v_ma := next_code('DX');
  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, doi_tuong_id, ten_doi_tuong, noi_dung,
    dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan, giai_trinh_ngoai_ke_hoach,
    han_thanh_toan, ton_kho, truong_bp_duyet, prepay, attachments)
  values (v_ma, coalesce((p_payload->>'ngayDeXuat')::date, current_date), coalesce(p_payload->>'nguoiDeNghi', v_actor.name),
    p_payload->>'boPhan', v_dt.id, v_dt.ten_doi_tuong, p_payload->>'noiDung',
    coalesce(p_payload->>'dieuKhoanTT', v_dt.dieu_khoan_tt_mac_dinh), v_status, v_actor.id, p_payload->>'ghiChu',
    v_loai, v_in_plan, v_giai_trinh, (p_payload->>'hanThanhToan')::date, parse_number(p_payload->>'tonKho'),
    coalesce((p_payload->>'truongBpDuyet')::boolean,false), coalesce((p_payload->>'prepay')::boolean,false),
    coalesce(p_payload->'attachments','[]'::jsonb))
  returning id into v_pid;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat'); v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then continue; end if;
    v_vat := parse_vat_rate(v_line->>'vat'); perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (next_code('DXL'), v_pid, trim(v_line->>'matHang'), v_qty, v_price, v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', v_status);
    v_n := v_n + 1;
  end loop;
  if v_n=0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;
  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai) into v_h from proposals where id=v_pid;
  perform write_audit(v_actor,'CREATE_PROPOSAL','proposals',v_ma,null,v_h,'OK',v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma, 'status', v_status);
end; $$;

create or replace function rpc_update_proposal(p_ma_de_xuat text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_dt doi_tuong; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ sửa được phiếu Nháp.'; end if;
  v_dt := ensure_doi_tuong(null, p_payload->'doiTuong'->>'ten', 'NCC', null, null, null, coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  update proposals set
    loai_de_xuat = case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end,
    ngay_de_xuat = coalesce((p_payload->>'ngayDeXuat')::date, ngay_de_xuat),
    nguoi_de_nghi = coalesce(p_payload->>'nguoiDeNghi', nguoi_de_nghi), bo_phan = p_payload->>'boPhan',
    doi_tuong_id = v_dt.id, ten_doi_tuong = v_dt.ten_doi_tuong, noi_dung = p_payload->>'noiDung',
    dieu_khoan_tt = coalesce(p_payload->>'dieuKhoanTT', dieu_khoan_tt), han_thanh_toan = (p_payload->>'hanThanhToan')::date,
    ton_kho = parse_number(p_payload->>'tonKho'), truong_bp_duyet = coalesce((p_payload->>'truongBpDuyet')::boolean,false),
    prepay = coalesce((p_payload->>'prepay')::boolean,false),
    trong_ke_hoach_tuan = coalesce((p_payload->>'trongKeHoachTuan')::boolean,false),
    giai_trinh_ngoai_ke_hoach = nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),''),
    attachments = case when p_payload ? 'attachments' and jsonb_array_length(p_payload->'attachments')>0 then p_payload->'attachments' else attachments end
  where id = v_p.id;
  delete from proposal_lines where proposal_id = v_p.id;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat'); v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then continue; end if;
    v_vat := parse_vat_rate(v_line->>'vat'); perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (next_code('DXL'), v_p.id, trim(v_line->>'matHang'), v_qty, v_price, v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', 'Nháp');
    v_n := v_n + 1;
  end loop;
  if v_n=0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

create or replace function rpc_approve_proposal(p_ma_de_xuat text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_proposal proposals; v_line proposal_lines; v_row_count int := 0; v_now date := current_date; v_new_debt_id uuid; v_total numeric; v_threshold numeric;
begin
  v_actor := require_permission('proposal:approve');
  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_proposal.trang_thai not in ('Chờ duyệt','Nháp') then raise exception 'Đề xuất % không ở trạng thái có thể duyệt.', p_ma_de_xuat; end if;
  select coalesce(sum(thanh_tien_sau_vat),0) into v_total from proposal_lines where proposal_id = v_proposal.id;
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key='approval_threshold';
  if v_actor.role not in ('Admin','ChuTich') and v_total >= v_threshold then
    raise exception 'Khoản % đ (≥ %) thuộc thẩm quyền CHỦ TỊCH.', to_char(v_total,'FM999,999,999'), to_char(v_threshold,'FM999,999,999');
  end if;
  for v_line in select * from proposal_lines where proposal_id = v_proposal.id loop
    insert into debts (ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no, proposal_id, ma_lo_hang,
      mat_hang, sl_dat, don_gia, vat_rate, dieu_khoan_tt, han_thanh_toan, prepay, ghi_chu, nguon_tao)
    values (next_code('CN'), v_proposal.ngay_de_xuat, v_now, v_proposal.doi_tuong_id, v_proposal.ten_doi_tuong,
      case when v_proposal.loai_de_xuat='TamUng' then 'TamUng' else 'AP' end, v_proposal.id, p_ma_de_xuat||'-'||lpad((v_row_count+1)::text,2,'0'),
      v_line.mat_hang, v_line.sl_dat, v_line.don_gia_chua_vat, v_line.vat_rate, v_proposal.dieu_khoan_tt, v_proposal.han_thanh_toan,
      v_proposal.prepay, format('WebApp | Nội dung: %s | Ghi chú: %s', coalesce(v_proposal.noi_dung,''), coalesce(v_line.ghi_chu,'')), 'WebApp')
    returning id into v_new_debt_id;
    v_row_count := v_row_count + 1;
    update proposal_lines set trang_thai='Đã duyệt', debt_id=v_new_debt_id where id=v_line.id;
  end loop;
  update proposals set trang_thai='Đã duyệt', nguoi_duyet=v_actor.id, approved_at=now(),
    ghi_chu = case when nullif(trim(coalesce(p_note,'')),'') is not null then coalesce(ghi_chu,'')||' | Duyệt: '||trim(p_note) else ghi_chu end
  where id=v_proposal.id;
  perform write_audit(v_actor,'APPROVE_PROPOSAL','proposals',p_ma_de_xuat,to_jsonb(v_proposal),jsonb_build_object('rows',v_row_count,'total',v_total),'OK',coalesce(nullif(trim(p_note),''),'Đã duyệt.'));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'congNoRows', v_row_count);
end; $$;

grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_update_proposal(text, jsonb) to authenticated;
grant execute on function rpc_approve_proposal(text, text) to authenticated;
grant execute on function rpc_preview_settlement(text) to authenticated;
grant execute on function rpc_confirm_settlement(text) to authenticated;
