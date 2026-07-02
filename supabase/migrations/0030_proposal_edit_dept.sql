-- ============================================================================
-- 0030_proposal_edit_dept.sql
--   * proposals: + bo_phan, + truong_bp_duyet (trưởng BP đã duyệt chưa)
--   * debts: + hoa_don_files (hóa đơn VAT ở bước nghiệm thu)
--   * departments (bộ phận) + proposers (người đề nghị) — danh mục cố định
--   * Sửa/đọc phiếu nháp (rpc_get_proposal, rpc_update_proposal)
--   * Cập nhật create_proposal / update_receipt / pending / approved / list_catalog
-- ============================================================================

alter table proposals add column if not exists bo_phan text;
alter table proposals add column if not exists truong_bp_duyet boolean not null default false;
alter table debts add column if not exists hoa_don_files jsonb not null default '[]'::jsonb;

create table if not exists departments (id uuid primary key default gen_random_uuid(), ten text unique not null, created_at timestamptz not null default now());
create table if not exists proposers  (id uuid primary key default gen_random_uuid(), ten text unique not null, bo_phan text, created_at timestamptz not null default now());
alter table departments enable row level security; revoke all on departments from anon, authenticated;
alter table proposers   enable row level security; revoke all on proposers   from anon, authenticated;

create or replace function rpc_add_department(p_ten text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ten text := nullif(trim(coalesce(p_ten,'')),'');
begin
  v_actor := require_permission('user:manage');
  if v_ten is null then raise exception 'Cần nhập tên bộ phận.'; end if;
  insert into departments (ten) values (v_ten) on conflict (ten) do nothing;
  return jsonb_build_object('ok', true, 'departments', (select coalesce(jsonb_agg(ten order by ten),'[]'::jsonb) from departments));
end; $$;

create or replace function rpc_add_proposer(p_ten text, p_bo_phan text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ten text := nullif(trim(coalesce(p_ten,'')),'');
begin
  v_actor := require_permission('catalog:manage');
  if v_ten is null then raise exception 'Cần nhập tên người đề nghị.'; end if;
  insert into proposers (ten, bo_phan) values (v_ten, nullif(trim(coalesce(p_bo_phan,'')),'')) on conflict (ten) do update set bo_phan = excluded.bo_phan;
  return jsonb_build_object('ok', true, 'proposers', (select coalesce(jsonb_agg(jsonb_build_object('ten',ten,'boPhan',bo_phan) order by ten),'[]'::jsonb) from proposers));
end; $$;

-- list_catalog + departments + proposers
create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_materials jsonb; v_suppliers jsonb; v_groups jsonb; v_depts jsonb; v_props jsonb;
begin
  perform require_permission('catalog:read');
  select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb) into v_groups from material_groups;
  select coalesce(jsonb_agg(ten order by ten), '[]'::jsonb) into v_depts from departments;
  select coalesce(jsonb_agg(jsonb_build_object('ten',ten,'boPhan',bo_phan) order by ten), '[]'::jsonb) into v_props from proposers;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'ma', ma_vat_tu, 'ten', ten, 'dvt', dvt, 'nhom', nhom, 'trangThai', trang_thai) order by nhom nulls last, ten), '[]'::jsonb) into v_materials from materials;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'ma', ma_doi_tuong, 'ten', ten_doi_tuong, 'loai', loai, 'mst', mst, 'diaChi', dia_chi, 'contact', contact, 'sdt', sdt, 'dieuKhoan', dieu_khoan_tt_mac_dinh, 'moq', moq, 'soTk', so_tk_ngan_hang, 'chiNhanh', chi_nhanh_ngan_hang, 'trangThai', trang_thai) order by ten_doi_tuong), '[]'::jsonb) into v_suppliers from doi_tuong;
  return jsonb_build_object('ok', true, 'groups', v_groups, 'departments', v_depts, 'proposers', v_props, 'materials', v_materials, 'suppliers', v_suppliers);
end; $$;

-- create_proposal + bo_phan, truong_bp_duyet
create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status', 'Nháp') = 'Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_loai text := case when coalesce(p_payload->>'loaiDeXuat','MuaHang') = 'TamUng' then 'TamUng' else 'MuaHang' end;
  v_in_plan boolean := coalesce((p_payload->>'trongKeHoachTuan')::boolean, false);
  v_giai_trinh text := nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')), '');
  v_actor profiles; v_doi_tuong doi_tuong; v_ma_de_xuat text; v_proposal_id uuid;
  v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_line_count int := 0; v_header jsonb;
begin
  v_actor := require_permission(case when v_status = 'Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);
  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines') = 0 then raise exception 'Đề xuất cần ít nhất một dòng vật tư.'; end if;
  if v_status = 'Chờ duyệt' and not v_in_plan and v_giai_trinh is null then raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.'; end if;
  v_doi_tuong := ensure_doi_tuong(p_payload->'doiTuong'->>'ma', p_payload->'doiTuong'->>'ten', coalesce(p_payload->'doiTuong'->>'loai','NCC'),
    p_payload->'doiTuong'->>'mst', p_payload->'doiTuong'->>'diaChi', p_payload->'doiTuong'->>'contact', coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  v_ma_de_xuat := next_code('DX');
  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, doi_tuong_id, ten_doi_tuong, noi_dung,
    dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan, giai_trinh_ngoai_ke_hoach,
    han_thanh_toan, ton_kho, truong_bp_duyet, attachments)
  values (v_ma_de_xuat, coalesce((p_payload->>'ngayDeXuat')::date, current_date), coalesce(p_payload->>'nguoiDeNghi', v_actor.name),
    p_payload->>'boPhan', v_doi_tuong.id, v_doi_tuong.ten_doi_tuong, p_payload->>'noiDung',
    coalesce(p_payload->>'dieuKhoanTT', v_doi_tuong.dieu_khoan_tt_mac_dinh), v_status, v_actor.id, p_payload->>'ghiChu',
    v_loai, v_in_plan, v_giai_trinh, (p_payload->>'hanThanhToan')::date, parse_number(p_payload->>'tonKho'),
    coalesce((p_payload->>'truongBpDuyet')::boolean, false), coalesce(p_payload->'attachments','[]'::jsonb))
  returning id into v_proposal_id;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat'); v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then continue; end if;
    v_vat := parse_vat_rate(v_line->>'vat'); perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (next_code('DXL'), v_proposal_id, trim(v_line->>'matHang'), v_qty, v_price, v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', v_status);
    v_line_count := v_line_count + 1;
  end loop;
  if v_line_count = 0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;
  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai) into v_header from proposals where id = v_proposal_id;
  perform write_audit(v_actor, 'CREATE_PROPOSAL', 'proposals', v_ma_de_xuat, null, v_header, 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma_de_xuat, 'status', v_status);
end; $$;

-- Đọc 1 phiếu để SỬA (chỉ chủ phiếu, mọi trạng thái)
create or replace function rpc_get_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  select jsonb_build_object('MaDeXuat', v_p.ma_de_xuat, 'TrangThai', v_p.trang_thai, 'LoaiDeXuat', v_p.loai_de_xuat,
    'NgayDeXuat', to_char(v_p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', v_p.nguoi_de_nghi, 'BoPhan', v_p.bo_phan,
    'TenDoiTuong', v_p.ten_doi_tuong, 'DieuKhoanTT', v_p.dieu_khoan_tt, 'HanThanhToan', to_char(v_p.han_thanh_toan,'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho, 'TruongBpDuyet', v_p.truong_bp_duyet, 'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan,
    'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach, 'Attachments', v_p.attachments,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('matHang', l.mat_hang, 'slDat', l.sl_dat, 'donGia', l.don_gia_chua_vat, 'vat', (l.vat_rate*100)||'%', 'ghiChu', l.ghi_chu) order by l.ma_line),'[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id))
  into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

-- Cập nhật 1 phiếu NHÁP (thay toàn bộ dòng)
create or replace function rpc_update_proposal(p_ma_de_xuat text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_doi_tuong doi_tuong; v_line jsonb; v_qty numeric; v_price numeric; v_vat numeric; v_n int := 0;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất.'; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ sửa được phiếu đang ở trạng thái Nháp.'; end if;
  v_doi_tuong := ensure_doi_tuong(null, p_payload->'doiTuong'->>'ten', 'NCC', null, null, null, coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT'));
  update proposals set
    loai_de_xuat = case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end,
    ngay_de_xuat = coalesce((p_payload->>'ngayDeXuat')::date, ngay_de_xuat),
    nguoi_de_nghi = coalesce(p_payload->>'nguoiDeNghi', nguoi_de_nghi), bo_phan = p_payload->>'boPhan',
    doi_tuong_id = v_doi_tuong.id, ten_doi_tuong = v_doi_tuong.ten_doi_tuong, noi_dung = p_payload->>'noiDung',
    dieu_khoan_tt = coalesce(p_payload->>'dieuKhoanTT', dieu_khoan_tt), han_thanh_toan = (p_payload->>'hanThanhToan')::date,
    ton_kho = parse_number(p_payload->>'tonKho'), truong_bp_duyet = coalesce((p_payload->>'truongBpDuyet')::boolean,false),
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
  if v_n = 0 then raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.'; end if;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

-- update_receipt + hóa đơn VAT
create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_ma_cn text := trim(coalesce(p_payload->>'maCN','')); v_qty numeric; v_before debts; v_after debts;
begin
  v_actor := require_permission('receipt:update');
  if v_ma_cn = '' then raise exception 'Cần chọn Mã CN/ĐX cần nghiệm thu.'; end if;
  v_qty := parse_number(p_payload->>'slThucNhan'); if v_qty is null then raise exception 'Cần nhập SL thực nhận.'; end if;
  select * into v_before from debts where ma_cn = v_ma_cn; if v_before is null then raise exception 'Không tìm thấy mã công nợ %.', v_ma_cn; end if;
  update debts set sl_thuc_nhan = v_qty, ngay_nhan = coalesce((p_payload->>'ngayNhan')::date, current_date),
    ma_chung_tu = coalesce(nullif(trim(coalesce(p_payload->>'chungTu','')),''), ma_chung_tu),
    han_thanh_toan = coalesce((p_payload->>'hanThanhToan')::date, han_thanh_toan),
    ho_so_day_du = coalesce((p_payload->>'hoSoDayDu')::boolean, false),
    nghiem_thu_files = coalesce(p_payload->'files', nghiem_thu_files),
    hoa_don_files = coalesce(p_payload->'hoaDonFiles', hoa_don_files),
    nghiem_thu_at = now(), nghiem_thu_by = v_actor.id,
    ghi_chu = case when coalesce(trim(p_payload->>'ghiChu'),'')<>'' then coalesce(ghi_chu||' | ','')||'Nghiệm thu: '||(p_payload->>'ghiChu') else ghi_chu end
  where id = v_before.id returning * into v_after;
  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', '');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end; $$;

-- pending + approved trả thêm BoPhan, TruongBpDuyet (để lãnh đạo thấy)
create or replace function rpc_get_pending_proposals(p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_threshold numeric; v_rows jsonb;
begin
  v_actor := require_permission('proposal:approve');
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';
  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_rows
  from (
    select p.created_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'LoaiDeXuat', p.loai_de_xuat, 'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'TenDoiTuong', p.ten_doi_tuong, 'NoiDung', p.noi_dung, 'DieuKhoanTT', p.dieu_khoan_tt,
        'HanThanhToan', to_char(p.han_thanh_toan, 'YYYY-MM-DD'), 'TonKho', p.ton_kho,
        'BoPhan', p.bo_phan, 'TruongBpDuyet', p.truong_bp_duyet,
        'NguoiDeNghi', p.nguoi_de_nghi, 'TrangThai', p.trang_thai, 'GhiChu', p.ghi_chu,
        'TrongKeHoachTuan', p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', p.giai_trinh_ngoai_ke_hoach, 'Attachments', p.attachments,
        'TongTien', t.v_tong,
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('MaLine', l.ma_line, 'MatHang', l.mat_hang, 'SLDat', l.sl_dat,
            'DonGiaChuaVAT', l.don_gia_chua_vat, 'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id)
      ) as row_data
    from proposals p
    cross join lateral (select coalesce(sum(thanh_tien_sau_vat),0) as v_tong from proposal_lines where proposal_id = p.id) t
    where p.trang_thai = 'Chờ duyệt'
      and (v_actor.role in ('Admin','ChuTich') or (v_actor.role = 'TongGiamDoc' and t.v_tong < v_threshold) or v_actor.role not in ('ChuTich','TongGiamDoc','Admin'))
    order by p.created_at desc limit least(greatest(coalesce(p_limit,50),1),200)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;

create or replace function rpc_get_approved_proposals(p_date date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_date date := coalesce(p_date, current_date); v_rows jsonb;
begin
  perform require_permission('proposal:approve');
  select coalesce(jsonb_agg(row_data order by approved_at desc), '[]'::jsonb) into v_rows
  from (
    select p.approved_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'LoaiDeXuat', p.loai_de_xuat, 'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD HH24:MI'), 'TenDoiTuong', p.ten_doi_tuong, 'NoiDung', p.noi_dung,
        'NguoiDeNghi', p.nguoi_de_nghi, 'BoPhan', p.bo_phan, 'TruongBpDuyet', p.truong_bp_duyet,
        'NguoiDuyet', (select name from profiles where id = p.nguoi_duyet), 'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'), 'Attachments', p.attachments,
        'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0),
        'DaPhatSinhTT', exists (select 1 from debts d where d.proposal_id = p.id and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))),
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
            'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id)
      ) as row_data
    from proposals p
    where p.trang_thai = 'Đã duyệt' and p.approved_at is not null and (p.approved_at at time zone 'Asia/Ho_Chi_Minh')::date = v_date
    order by p.approved_at desc
  ) x;
  return jsonb_build_object('ok', true, 'date', to_char(v_date, 'YYYY-MM-DD'), 'rows', v_rows);
end; $$;

grant execute on function rpc_get_pending_proposals(int) to authenticated;
grant execute on function rpc_get_approved_proposals(date) to authenticated;
grant execute on function rpc_add_department(text) to authenticated;
grant execute on function rpc_add_proposer(text, text) to authenticated;
grant execute on function rpc_list_catalog() to authenticated;
grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_get_proposal(text) to authenticated;
grant execute on function rpc_update_proposal(text, jsonb) to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
