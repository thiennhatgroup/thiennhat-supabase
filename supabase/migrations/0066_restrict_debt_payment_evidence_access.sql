-- ============================================================================
-- 0066_restrict_debt_payment_evidence_access.sql
--  Restrict sensitive debt and payment evidence at the RPC layer.
--
--  Rules:
--    * Proposal creators can see evidence for their own proposal/debt.
--    * KTTH, cashier, and Admin can see evidence needed for their workflows.
--    * Unrelated purchasing staff cannot read supplier bank data, VAT/BBGN
--      files, debt detail, or payment proof for other users' proposals.
--    * Keep the existing RPC-first model; do not introduce storage changes.
-- ============================================================================

create or replace function app_can_view_sensitive_payment_evidence(p_actor profiles)
returns boolean
language sql stable as $$
  select coalesce(p_actor.role in ('Admin','KeToanCongNo'), false);
$$;

create or replace function app_can_view_debt_evidence(p_debt debts, p_actor profiles)
returns boolean
language plpgsql stable as $$
begin
  if app_can_view_sensitive_payment_evidence(p_actor) then
    return true;
  end if;

  if p_actor.role = 'ThuQuy' then
    return exists (
      select 1
      from payment_request_lines l
      join payment_requests pr on pr.id = l.request_id
      where l.debt_id = p_debt.id
        and pr.trang_thai = 'Đã duyệt'
    )
    or (
      p_debt.sl_thuc_nhan is not null
      and p_debt.cong_no_confirmed = false
      and p_debt.prepay = false
      and p_debt.cho_bo_sung = false
    );
  end if;

  if p_debt.proposal_id is null then
    return false;
  end if;

  return exists (
    select 1
    from proposals p
    where p.id = p_debt.proposal_id
      and p.nguoi_tao = p_actor.id
  );
end;
$$;

create or replace function app_can_update_receipt_evidence(p_debt debts, p_actor profiles)
returns boolean
language plpgsql stable as $$
begin
  if p_actor.role in ('Admin','KeToanCongNo') then
    return true;
  end if;

  if p_debt.proposal_id is null then
    return false;
  end if;

  return exists (
    select 1
    from proposals p
    where p.id = p_debt.proposal_id
      and p.nguoi_tao = p_actor.id
  );
end;
$$;

-- ---- Catalog: keep bank fields out of general NVMH catalog reads ------------
create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_all boolean;
  v_can_sensitive boolean;
  v_actor_bp text;
  v_actor_department_id uuid;
  v_materials jsonb;
  v_suppliers jsonb;
  v_groups jsonb;
  v_depts jsonb;
  v_props jsonb;
begin
  v_actor := require_permission('catalog:read');
  v_all := v_actor.role not in ('NhanVienMuaHang','TruongPhong');
  v_can_sensitive := app_can_view_sensitive_payment_evidence(v_actor);
  v_actor_bp := app_profile_department_name(v_actor);
  v_actor_department_id := app_profile_department_id(v_actor);

  select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb)
    into v_groups
  from material_groups;

  select coalesce(jsonb_agg(d.ten order by d.ten), '[]'::jsonb)
    into v_depts
  from departments d
  where v_all
     or d.id = v_actor_department_id
     or (v_actor_bp is not null and normalize_text(d.ten) = normalize_text(v_actor_bp));

  select coalesce(jsonb_agg(jsonb_build_object('ten', p.ten, 'boPhan', p.bo_phan) order by p.ten), '[]'::jsonb)
    into v_props
  from proposers p
  where v_all
     or p.bo_phan is null
     or (v_actor_bp is not null and normalize_text(p.bo_phan) = normalize_text(v_actor_bp));

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'ma', m.ma_vat_tu, 'ten', m.ten, 'dvt', m.dvt, 'nhom', m.nhom,
      'boPhan', m.bo_phan, 'trangThai', m.trang_thai
    ) order by m.nhom nulls last, m.ten), '[]'::jsonb)
    into v_materials
  from materials m
  where v_all
     or m.bo_phan is null
     or (v_actor_bp is not null and normalize_text(m.bo_phan) = normalize_text(v_actor_bp));

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', dt.id, 'ma', dt.ma_doi_tuong, 'ten', dt.ten_doi_tuong, 'loai', dt.loai,
      'mst', dt.mst, 'diaChi', dt.dia_chi, 'contact', dt.contact, 'sdt', dt.sdt,
      'dieuKhoan', dt.dieu_khoan_tt_mac_dinh, 'moq', dt.moq,
      'soTk', case when v_can_sensitive then dt.so_tk_ngan_hang else null end,
      'chiNhanh', case when v_can_sensitive then dt.chi_nhanh_ngan_hang else null end,
      'boPhan', dt.bo_phan, 'trangThai', dt.trang_thai
    ) order by dt.ten_doi_tuong), '[]'::jsonb)
    into v_suppliers
  from doi_tuong dt
  where v_all
     or dt.bo_phan is null
     or (v_actor_bp is not null and normalize_text(dt.bo_phan) = normalize_text(v_actor_bp));

  return jsonb_build_object(
    'ok', true,
    'groups', v_groups,
    'departments', v_depts,
    'proposers', v_props,
    'materials', v_materials,
    'suppliers', v_suppliers,
    'canCreate', (v_actor.role = 'Admin' or has_permission(v_actor.role, 'catalog:create')),
    'canManage', (v_actor.role = 'Admin' or has_permission(v_actor.role, 'catalog:manage'))
  );
end;
$$;

-- ---- NVMH receipt work queue: own proposal only; KTTH/Admin all -------------
create or replace function rpc_get_open_receipt_items(p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_rows jsonb;
begin
  v_actor := require_permission('receipt:update');

  select coalesce(jsonb_agg(row_data order by (row_data->>'ChoBoSung') desc, (row_data->>'NgayDuyet') desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'MaCN', d.ma_cn, 'MaDeXuat', p.ma_de_xuat, 'MaDoiTuong', dt.ma_doi_tuong,
      'TenDoiTuong', d.ten_doi_tuong,
      'MatHang', d.mat_hang, 'dvt', (select m.dvt from materials m where m.id = d.material_id),
      'SLDat', d.sl_dat, 'SLThucNhan', d.sl_thuc_nhan, 'DonGia', d.don_gia, 'VATRate', d.vat_rate,
      'ThanhTienDat', round(coalesce(d.sl_dat,0) * d.don_gia * (1 + d.vat_rate), 2),
      'NguoiDeNghi', p.nguoi_de_nghi, 'DieuKhoanTT', d.dieu_khoan_tt,
      'HanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD'),
      'Attachments', coalesce(p.attachments,'[]'::jsonb),
      'ChungTuTypes', coalesce(d.chung_tu_types,'[]'::jsonb),
      'ChoBoSung', d.cho_bo_sung, 'LyDoBoSung', d.ly_do_bo_sung,
      'NgayDuyet', to_char(d.ngay_duyet, 'YYYY-MM-DD')
    ) as row_data
    from debts d
    left join proposals p on p.id = d.proposal_id
    left join doi_tuong dt on dt.id = d.doi_tuong_id
    where d.is_archived = false
      and (d.sl_thuc_nhan is null or d.cho_bo_sung = true)
      and (
        v_actor.role in ('Admin','KeToanCongNo')
        or p.nguoi_tao = v_actor.id
      )
    order by d.created_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) x;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_get_receipt_history(p_limit int default 40) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_rows jsonb;
begin
  v_actor := require_permission('receipt:update');

  select coalesce(jsonb_agg(jsonb_build_object(
      'MaCN', d.ma_cn, 'TenDoiTuong', d.ten_doi_tuong, 'MatHang', d.mat_hang,
      'SLThucNhan', d.sl_thuc_nhan, 'NgayNhan', to_char(d.ngay_nhan,'YYYY-MM-DD'),
      'HoSoDayDu', d.ho_so_day_du, 'HanThanhToan', to_char(d.han_thanh_toan,'YYYY-MM-DD')
    ) order by d.nghiem_thu_at desc nulls last), '[]'::jsonb)
    into v_rows
  from (
    select d.*
    from debts d
    left join proposals p on p.id = d.proposal_id
    where d.sl_thuc_nhan is not null
      and (
        v_actor.role in ('Admin','KeToanCongNo')
        or p.nguoi_tao = v_actor.id
      )
    order by d.nghiem_thu_at desc nulls last
    limit least(greatest(coalesce(p_limit,40),1),200)
  ) d;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- ---- Receipt update: only own proposal, KTTH, or Admin ----------------------
create or replace function rpc_update_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ma_cn text := trim(coalesce(p_payload->>'maCN',''));
  v_qty numeric;
  v_before debts;
  v_after debts;
  v_nguoi text;
  v_tong numeric;
  v_msg text;
  v_stk text := nullif(trim(coalesce(p_payload->>'soTk','')),'');
  v_cn text := nullif(trim(coalesce(p_payload->>'chiNhanh','')),'');
  v_hd text := nullif(trim(coalesce(p_payload->>'soHoaDon','')),'');
begin
  v_actor := require_permission('receipt:update');
  if v_ma_cn = '' then raise exception 'Cần chọn Mã CN/ĐX cần nghiệm thu.'; end if;

  v_qty := parse_number(p_payload->>'slThucNhan');
  if v_qty is null then raise exception 'Cần nhập SL thực nhận (khối lượng nghiệm thu).'; end if;
  if v_stk is null then raise exception 'Bắt buộc nhập Số tài khoản NCC.'; end if;
  if v_cn is null then raise exception 'Bắt buộc nhập Chi nhánh ngân hàng NCC.'; end if;
  if v_hd is null then raise exception 'Bắt buộc nhập Số hóa đơn VAT.'; end if;

  select * into v_before from debts where ma_cn = v_ma_cn;
  if v_before is null or not app_can_update_receipt_evidence(v_before, v_actor) then
    raise exception 'Không tìm thấy khoản hoặc bạn không có quyền cập nhật.';
  end if;

  update debts set
    sl_thuc_nhan = v_qty,
    ngay_nhan = coalesce((p_payload->>'ngayNhan')::date, current_date),
    ma_chung_tu = coalesce(nullif(trim(coalesce(p_payload->>'chungTu','')),''), ma_chung_tu),
    so_hoa_don_vat = v_hd,
    han_thanh_toan = coalesce((p_payload->>'hanThanhToan')::date, han_thanh_toan),
    chung_tu_types = coalesce(p_payload->'chungTuTypes', '[]'::jsonb),
    nghiem_thu_files = coalesce(p_payload->'files', nghiem_thu_files),
    ho_so_day_du = (jsonb_array_length(coalesce(p_payload->'chungTuTypes','[]'::jsonb)) > 0),
    cho_bo_sung = false, ly_do_bo_sung = null,
    nghiem_thu_at = now(), nghiem_thu_by = v_actor.id,
    ghi_chu = case
      when coalesce(trim(p_payload->>'ghiChu'),'') <> ''
      then coalesce(ghi_chu||' | ','') || 'Nghiệm thu: ' || (p_payload->>'ghiChu')
      else ghi_chu
    end
  where id = v_before.id
  returning * into v_after;

  if v_after.doi_tuong_id is not null then
    update doi_tuong
       set so_tk_ngan_hang = v_stk,
           chi_nhanh_ngan_hang = v_cn
     where id = v_after.doi_tuong_id;
  end if;

  select nguoi_de_nghi into v_nguoi from proposals where id = v_after.proposal_id;
  v_tong := round(coalesce(v_after.sl_thuc_nhan,0) * v_after.don_gia * (1 + v_after.vat_rate), 0);
  v_msg := v_ma_cn || ' - ' || coalesce(v_after.ten_doi_tuong,'')
           || case when coalesce(v_after.mat_hang,'') <> '' then ' · ' || v_after.mat_hang else '' end
           || ' · ' || to_char(v_tong,'FM999,999,999') || 'đ'
           || case when coalesce(v_nguoi,'') <> '' then ' · Đề nghị: ' || v_nguoi else '' end;

  insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
  select id, 'receipt_review', 'Đơn chờ duyệt chứng từ & lưu công nợ', v_msg, 'congnoconfirm', v_ma_cn
  from profiles
  where role in ('KeToanCongNo','Admin')
    and status = 'Hoạt động';

  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', 'Chờ kế toán duyệt hồ sơ.');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end;
$$;

-- ---- Shared debt detail: object-level evidence access ----------------------
create or replace function rpc_get_debt_detail(p_ma_cn text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_debt debts;
  v_j jsonb;
begin
  select * into v_actor from profiles where id = auth.uid();
  if v_actor is null then
    raise exception 'Chưa đăng nhập.';
  end if;
  if v_actor.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;

  select * into v_debt
  from debts
  where ma_cn = trim(coalesce(p_ma_cn,''));

  if v_debt is null or not app_can_view_debt_evidence(v_debt, v_actor) then
    raise exception 'Không tìm thấy khoản hoặc bạn không có quyền xem.';
  end if;

  select jsonb_build_object(
    'maCN', vd.ma_cn, 'maDeXuat', p.ma_de_xuat, 'tenDoiTuong', vd.ten_doi_tuong,
    'boPhan', p.bo_phan, 'nguoiDeNghi', p.nguoi_de_nghi,
    'matHang', vd.mat_hang, 'dvt', (select m.dvt from materials m where m.id = vd.material_id),
    'slDat', vd.sl_dat, 'slThucNhan', vd.sl_thuc_nhan, 'donGia', vd.don_gia, 'vatRate', vd.vat_rate,
    'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', vd.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
    'hanThanhToan', to_char(vd.han_thanh_toan,'YYYY-MM-DD'), 'ngayNhan', to_char(vd.ngay_nhan,'YYYY-MM-DD'),
    'dieuKhoanTT', vd.dieu_khoan_tt, 'trangThai', vd.trang_thai_dong,
    'soHoaDonVat', d.so_hoa_don_vat,
    'chungTuTypes', coalesce(vd.chung_tu_types,'[]'::jsonb),
    'nghiemThuFiles', coalesce(d.nghiem_thu_files,'[]'::jsonb),
    'baoGia', coalesce(p.attachments,'[]'::jsonb),
    'soTk', dt.so_tk_ngan_hang, 'chiNhanh', dt.chi_nhanh_ngan_hang, 'mst', dt.mst,
    'thoiGianDeXuat', to_char(p.created_at,'YYYY-MM-DD HH24:MI'),
    'thoiGianSepDuyet', to_char(p.approved_at,'YYYY-MM-DD HH24:MI'),
    'nguoiSepDuyet', (select name from profiles where id = p.nguoi_duyet),
    'nguoiNghiemThu', (select name from profiles where id = d.nghiem_thu_by),
    'thoiGianNghiemThu', to_char(d.nghiem_thu_at,'YYYY-MM-DD HH24:MI'),
    'ktthDuyet', (select name from profiles where id = d.cong_no_confirmed_by),
    'thoiGianKtthDuyet', to_char(d.cong_no_confirmed_at,'YYYY-MM-DD HH24:MI')
  ) into v_j
  from v_debts vd
  join debts d on d.id = vd.id
  left join doi_tuong dt on dt.id = vd.doi_tuong_id
  left join proposals p on p.id = d.proposal_id
  where d.id = v_debt.id;

  return jsonb_build_object('ok', true, 'debt', v_j);
end;
$$;

-- ---- Payment history: future-proof proof files against broad payment:create -
create or replace function rpc_list_payments(p_ma_doi_tuong text default null, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_can_sensitive boolean;
  v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),'');
  v_rows jsonb;
begin
  v_actor := require_permission('payment:create');
  v_can_sensitive := app_can_view_sensitive_payment_evidence(v_actor);

  select coalesce(jsonb_agg(x order by (x->>'createdAt') desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'maThanhToan', p.ma_thanh_toan, 'ngay', to_char(p.ngay_thanh_toan,'YYYY-MM-DD'),
      'tenDoiTuong', p.ten_doi_tuong,
      'maCN', p.ma_cn, 'soTien', p.so_tien, 'ghiChu', p.ghi_chu,
      'nguoi', (select name from profiles where id = p.nguoi_nhap),
      'anhChuyenKhoan', case when v_can_sensitive then coalesce(p.proof_files,'[]'::jsonb) else '[]'::jsonb end,
      'createdAt', to_char(p.created_at,'YYYY-MM-DD HH24:MI:SS')
    ) as x
    from payments p
    left join doi_tuong dt on dt.id = p.doi_tuong_id
    where (v_ma is null or dt.ma_doi_tuong = v_ma)
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit,50),1),200)
  ) t;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- ---- Payment approval detail: approvers can view facts, not attachment files -
create or replace function rpc_payment_request_detail(p_ma text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_can_sensitive boolean;
  v_pr payment_requests;
  v_j jsonb;
begin
  v_actor := require_permission('payment:approve');
  v_can_sensitive := app_can_view_sensitive_payment_evidence(v_actor);

  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then
    raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma;
  end if;

  select jsonb_build_object(
    'MaDeXuatTT', v_pr.ma_de_xuat_tt,
    'Ngay', to_char(v_pr.ngay, 'YYYY-MM-DD'),
    'TrangThai', v_pr.trang_thai,
    'GhiChu', v_pr.ghi_chu,
    'NguoiLap', (select name from profiles where id = v_pr.nguoi_lap),
    'ThoiGianLap', to_char(v_pr.created_at, 'YYYY-MM-DD HH24:MI'),
    'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id = v_pr.id), 0),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ncc', l.ncc, 'keHoach', l.ke_hoach, 'soTien', l.so_tien, 'noiDung', l.noi_dung,
        'hinhThucTT', l.hinh_thuc_tt, 'tinhTrangHoSo', l.tinh_trang_ho_so, 'giaiTrinh', l.giai_trinh,
        'linked', (l.debt_id is not null),
        'maCN', d.ma_cn, 'matHang', d.mat_hang, 'dvt', m.dvt,
        'slDat', d.sl_dat, 'slThucNhan', d.sl_thuc_nhan, 'donGia', d.don_gia, 'vatRate', d.vat_rate,
        'thanhTienThucNhan', vd.thanh_tien_thuc_nhan, 'daThanhToan', d.da_thanh_toan, 'soDuConLai', vd.so_tien_con_lai,
        'hanThanhToan', to_char(d.han_thanh_toan, 'YYYY-MM-DD'), 'ngayNhan', to_char(d.ngay_nhan, 'YYYY-MM-DD'),
        'dieuKhoanTT', d.dieu_khoan_tt, 'hoSoDayDu', d.ho_so_day_du,
        'nghiemThuFiles', case when v_can_sensitive then coalesce(d.nghiem_thu_files, '[]'::jsonb) else '[]'::jsonb end,
        'maDeXuat', p.ma_de_xuat, 'nguoiDeNghi', p.nguoi_de_nghi, 'boPhan', p.bo_phan,
        'baoGia', case when v_can_sensitive then coalesce(p.attachments, '[]'::jsonb) else '[]'::jsonb end
      ) order by l.created_at)
      from payment_request_lines l
      left join debts d on d.id = l.debt_id
      left join v_debts vd on vd.id = d.id
      left join materials m on m.id = d.material_id
      left join proposals p on p.id = d.proposal_id
      where l.request_id = v_pr.id
    ), '[]'::jsonb)
  ) into v_j;

  return jsonb_build_object('ok', true, 'pr', v_j);
end;
$$;

-- ---- Dashboard: preserve metrics, mask payment proof outside evidence roles --
create or replace function rpc_leader_dashboard(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_can_sensitive boolean;
  v_from date := coalesce(p_from, current_date - 30);
  v_to date := coalesce(p_to, current_date);
  v_dxmh jsonb;
  v_dxmh_bp jsonb;
  v_dxtt jsonb;
  v_chi jsonb;
  v_chi_bp jsonb;
  v_chi_detail jsonb;
  v_topncc jsonb;
begin
  v_actor := require_permission('dashboard:read');
  v_can_sensitive := app_can_view_sensitive_payment_evidence(v_actor);

  select jsonb_build_object('count', count(*),
    'total', coalesce(sum((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id)), 0))
    into v_dxmh
  from proposals p
  where p.created_at::date = current_date
    and p.trang_thai <> 'Nháp';

  select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'total', t) order by t desc), '[]'::jsonb)
    into v_dxmh_bp
  from (
    select coalesce(p.bo_phan,'(không rõ)') as bp,
      coalesce(sum((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id)),0) as t
    from proposals p
    where p.created_at::date = current_date
      and p.trang_thai <> 'Nháp'
    group by 1
  ) s;

  select jsonb_build_object('count', count(distinct pr.id), 'total', coalesce(sum(l.so_tien), 0))
    into v_dxtt
  from payment_requests pr
  join payment_request_lines l on l.request_id = pr.id
  where pr.ngay = current_date
    and pr.trang_thai <> 'Nháp';

  select jsonb_build_object('total', coalesce(sum(pm.so_tien),0), 'count', count(*))
    into v_chi
  from payments pm
  where pm.ngay_thanh_toan between v_from and v_to;

  select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'total', t) order by t desc), '[]'::jsonb)
    into v_chi_bp
  from (
    select coalesce(pr.bo_phan, '(ngoài phần mềm)') as bp, sum(pm.so_tien) as t
    from payments pm
    left join debts d on d.ma_cn = pm.ma_cn
    left join proposals pr on pr.id = d.proposal_id
    where pm.ngay_thanh_toan between v_from and v_to
    group by 1
  ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
    'maThanhToan', pm.ma_thanh_toan, 'ngay', to_char(pm.ngay_thanh_toan,'YYYY-MM-DD'),
    'ncc', pm.ten_doi_tuong, 'soTien', pm.so_tien, 'maCN', pm.ma_cn,
    'boPhan', coalesce(pr.bo_phan,'(ngoài phần mềm)'), 'ghiChu', pm.ghi_chu,
    'proof', case when v_can_sensitive then coalesce(pm.proof_files,'[]'::jsonb) else '[]'::jsonb end
  ) order by pm.ngay_thanh_toan desc, pm.created_at desc), '[]'::jsonb)
    into v_chi_detail
  from (
    select *
    from payments pm2
    where pm2.ngay_thanh_toan between v_from and v_to
    order by pm2.ngay_thanh_toan desc, pm2.created_at desc
    limit 500
  ) pm
  left join debts d on d.ma_cn = pm.ma_cn
  left join proposals pr on pr.id = d.proposal_id;

  select coalesce(jsonb_agg(jsonb_build_object('ncc', ncc, 'boPhan', bp, 'total', t) order by t desc), '[]'::jsonb)
    into v_topncc
  from (
    select coalesce(pm.ten_doi_tuong,'(không rõ)') as ncc, coalesce(pr.bo_phan,'(ngoài phần mềm)') as bp, sum(pm.so_tien) as t
    from payments pm
    left join debts d on d.ma_cn = pm.ma_cn
    left join proposals pr on pr.id = d.proposal_id
    where pm.ngay_thanh_toan between v_from and v_to
    group by 1, 2
    order by t desc
    limit 15
  ) s;

  return jsonb_build_object(
    'ok', true,
    'from', to_char(v_from,'YYYY-MM-DD'),
    'to', to_char(v_to,'YYYY-MM-DD'),
    'dxmhToday', v_dxmh,
    'dxmhByBoPhan', v_dxmh_bp,
    'dxttToday', v_dxtt,
    'chi', v_chi,
    'chiByBoPhan', v_chi_bp,
    'chiDetail', v_chi_detail,
    'topNcc', v_topncc
  );
end;
$$;

revoke all on function app_can_view_sensitive_payment_evidence(profiles) from public, anon, authenticated;
revoke all on function app_can_view_debt_evidence(debts, profiles) from public, anon, authenticated;
revoke all on function app_can_update_receipt_evidence(debts, profiles) from public, anon, authenticated;

grant execute on function rpc_list_catalog() to authenticated;
grant execute on function rpc_get_open_receipt_items(int) to authenticated;
grant execute on function rpc_get_receipt_history(int) to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
grant execute on function rpc_get_debt_detail(text) to authenticated;
grant execute on function rpc_list_payments(text, int) to authenticated;
grant execute on function rpc_payment_request_detail(text) to authenticated;
grant execute on function rpc_leader_dashboard(date, date) to authenticated;
