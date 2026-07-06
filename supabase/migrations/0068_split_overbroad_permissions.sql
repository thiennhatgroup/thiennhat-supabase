-- ============================================================================
-- 0068_split_overbroad_permissions.sql
--  Split broad role permissions into narrower actions.
--
--  Security goals:
--    * Admin no longer has an implicit "*" bypass; admin powers are explicit.
--    * Department heads keep department-scoped proposal visibility, not cancel.
--    * KTTH keeps accounting/review/correction powers; cashier only executes
--      approved payments.
--    * Payment history reads are split from manual payment adjustment.
--    * Leadership dashboard is split from the normal debt dashboard.
--    * Evidence access keeps the accepted object rules from 0066.
-- ============================================================================

-- ---- Permission model: explicit grants, no Admin wildcard -------------------
create or replace function has_permission(p_role text, p_permission text) returns boolean
language sql stable as $$
  select exists (
    select 1
    from role_permissions
    where role = p_role
      and permission = p_permission
  );
$$;

delete from role_permissions where role = 'Admin';
delete from role_permissions where role = 'TruongPhong' and permission in ('catalog:manage', 'oversight:cancel');
delete from role_permissions where role = 'ThuQuy' and permission in ('dashboard:read', 'payment:read');
delete from role_permissions where role = 'KeToanCongNo' and permission in ('receipt:update', 'payment:create');
delete from role_permissions where role = 'NhanVienMuaHang' and permission = 'payment:create';
delete from role_permissions where permission = 'payment:create';
delete from role_permissions where permission = '*';

insert into role_permissions (role, permission) values
  ('Admin', 'user:manage'),
  ('Admin', 'department:manage'),

  ('KeToanCongNo', 'payment:read'),
  ('KeToanCongNo', 'payment:adjust'),
  ('KeToanCongNo', 'payment:request:read'),

  ('ChuTich', 'leaderdash:read'),
  ('TongGiamDoc', 'leaderdash:read')
on conflict (role, permission) do nothing;

grant execute on function has_permission(text, text) to authenticated;

-- ---- Bootstrap: return actual permissions for every role --------------------
create or replace function rpc_bootstrap() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile profiles;
  v_perms jsonb;
  v_all boolean;
  v_can_catalog boolean;
  v_department_name text;
begin
  select * into v_profile from profiles where id = auth.uid();
  if v_profile is null then
    raise exception 'Tài khoản chưa được cấp quyền truy cập hệ thống. Hãy liên hệ Admin để tạo hồ sơ trong bảng profiles.';
  end if;
  if v_profile.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;
  if v_profile.role in ('NhanVienMuaHang','TruongPhong') and app_profile_department_id(v_profile) is null then
    raise exception 'Tài khoản cần được Admin gán bộ phận trước khi sử dụng.';
  end if;

  select coalesce(jsonb_agg(permission order by permission), '[]'::jsonb)
    into v_perms
  from role_permissions
  where role = v_profile.role;

  v_all := v_profile.role not in ('NhanVienMuaHang','TruongPhong');
  v_department_name := app_profile_department_name(v_profile);
  v_can_catalog := has_permission(v_profile.role, 'catalog:read')
                or has_permission(v_profile.role, 'proposal:create')
                or has_permission(v_profile.role, 'payment:request')
                or has_permission(v_profile.role, 'receipt:update');

  return jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'email', v_profile.email,
      'name', v_profile.name,
      'role', v_profile.role,
      'departmentId', app_profile_department_id(v_profile),
      'boPhan', v_department_name
    ),
    'doiTuong', case when v_can_catalog then (
      select coalesce(jsonb_agg(jsonb_build_object(
        'MaDoiTuong', ma_doi_tuong,
        'TenDoiTuong', ten_doi_tuong,
        'DieuKhoanTT_MacDinh', dieu_khoan_tt_mac_dinh
      ) order by ten_doi_tuong), '[]'::jsonb)
      from doi_tuong
      where trang_thai = 'Hoạt động'
        and (v_all or bo_phan is null or normalize_text(bo_phan) = normalize_text(v_department_name))
    ) else '[]'::jsonb end,
    'vatTu', case when v_can_catalog then (
      select coalesce(jsonb_agg(ten order by ten), '[]'::jsonb)
      from materials
      where v_all or bo_phan is null or normalize_text(bo_phan) = normalize_text(v_department_name)
    ) else '[]'::jsonb end,
    'vatTuInfo', case when v_can_catalog then (
      select coalesce(jsonb_agg(jsonb_build_object('ten', ten, 'dvt', dvt) order by ten), '[]'::jsonb)
      from materials
      where v_all or bo_phan is null or normalize_text(bo_phan) = normalize_text(v_department_name)
    ) else '[]'::jsonb end,
    'permissions', v_perms
  );
end;
$$;

-- ---- Visibility helpers ----------------------------------------------------
create or replace function app_can_view_sensitive_payment_evidence(p_actor profiles)
returns boolean
language sql stable as $$
  select coalesce(p_actor.role = 'KeToanCongNo', false);
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

create or replace function app_can_view_proposal(p_proposal proposals, p_actor profiles) returns boolean
language plpgsql stable as $$
begin
  if p_proposal.nguoi_tao = p_actor.id then
    return true;
  end if;

  if p_actor.role = 'NhanVienMuaHang' then
    return false;
  end if;

  if p_proposal.trang_thai = 'Nháp' then
    return false;
  end if;

  if p_actor.role = 'TruongPhong' then
    return app_same_department(p_proposal, p_actor);
  end if;

  if p_actor.role in ('KeToanCongNo','LanhDao','ChuTich','TongGiamDoc') then
    return true;
  end if;

  return false;
end;
$$;

create or replace function app_can_list_proposal(p_proposal proposals, p_actor profiles) returns boolean
language plpgsql stable as $$
begin
  if p_proposal.nguoi_tao = p_actor.id then
    return true;
  end if;

  if p_proposal.trang_thai = 'Nháp' then
    return false;
  end if;

  return app_can_view_proposal(p_proposal, p_actor);
end;
$$;

create or replace function app_can_oversight_proposal(p_proposal proposals, p_actor profiles) returns boolean
language plpgsql stable as $$
begin
  if p_proposal.trang_thai = 'Nháp' then
    return false;
  end if;

  if p_actor.role = 'KeToanCongNo' then
    return true;
  end if;

  if p_actor.role = 'TruongPhong' then
    return app_same_department(p_proposal, p_actor);
  end if;

  return false;
end;
$$;

create or replace function app_can_view_debt_record(p_debt debts, p_actor profiles)
returns boolean
language plpgsql stable as $$
declare
  v_proposal proposals;
begin
  if p_actor.role = 'KeToanCongNo' then
    return true;
  end if;

  if p_debt.proposal_id is null then
    return false;
  end if;

  select * into v_proposal from proposals where id = p_debt.proposal_id;
  if v_proposal is null then
    return false;
  end if;

  if v_proposal.nguoi_tao = p_actor.id then
    return true;
  end if;

  if v_proposal.trang_thai = 'Nháp' then
    return false;
  end if;

  if p_actor.role = 'TruongPhong' then
    return app_same_department(v_proposal, p_actor);
  end if;

  if p_actor.role in ('LanhDao','ChuTich','TongGiamDoc') then
    return true;
  end if;

  return false;
end;
$$;

revoke all on function app_can_view_debt_record(debts, profiles) from public, anon, authenticated;

-- ---- Admin/departments -----------------------------------------------------
create or replace function rpc_add_department(p_ten text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_ten text := nullif(trim(coalesce(p_ten,'')), '');
begin
  v_actor := require_permission('department:manage');
  if v_ten is null then
    raise exception 'Cần nhập tên bộ phận.';
  end if;

  insert into departments (ten) values (v_ten)
  on conflict (ten) do nothing;

  perform write_audit(v_actor, 'ADD_DEPARTMENT', 'departments', v_ten, null, jsonb_build_object('ten', v_ten), 'OK', '');
  return jsonb_build_object(
    'ok', true,
    'departments', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'ten', ten) order by ten), '[]'::jsonb) from departments)
  );
end;
$$;

create or replace function rpc_admin_list_users() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform require_permission('user:manage');
  return jsonb_build_object(
    'ok', true,
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'email', p.email,
        'name', p.name,
        'role', p.role,
        'status', p.status,
        'departmentId', p.department_id,
        'boPhan', app_profile_department_name(p),
        'createdAt', to_char(p.created_at, 'YYYY-MM-DD HH24:MI')
      ) order by p.created_at desc), '[]'::jsonb)
      from profiles p
    )
  );
end;
$$;

-- ---- Catalog read stays scoped and no longer treats Admin as manager --------
create or replace function rpc_list_catalog() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_all boolean;
  v_can_sensitive boolean;
  v_can_catalog_read boolean;
  v_actor_bp text;
  v_actor_department_id uuid;
  v_materials jsonb;
  v_suppliers jsonb;
  v_groups jsonb;
  v_depts jsonb;
  v_props jsonb;
begin
  select * into v_actor from profiles where id = auth.uid();
  if v_actor is null then
    raise exception 'Tài khoản chưa được cấp quyền truy cập hệ thống.';
  end if;
  if v_actor.status <> 'Hoạt động' then
    raise exception 'Tài khoản chưa ở trạng thái Hoạt động.';
  end if;
  if not has_permission(v_actor.role, 'catalog:read')
     and not has_permission(v_actor.role, 'department:manage') then
    raise exception 'Bạn không có quyền thực hiện thao tác này (catalog:read).';
  end if;

  v_can_catalog_read := has_permission(v_actor.role, 'catalog:read');
  v_all := v_actor.role not in ('NhanVienMuaHang','TruongPhong');
  v_can_sensitive := app_can_view_sensitive_payment_evidence(v_actor);
  v_actor_bp := app_profile_department_name(v_actor);
  v_actor_department_id := app_profile_department_id(v_actor);

  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'ten', d.ten) order by d.ten), '[]'::jsonb)
    into v_depts
  from departments d
  where v_all
     or d.id = v_actor_department_id
     or (v_actor_bp is not null and normalize_text(d.ten) = normalize_text(v_actor_bp));

  if not v_can_catalog_read then
    v_groups := '[]'::jsonb;
    v_props := '[]'::jsonb;
    v_materials := '[]'::jsonb;
    v_suppliers := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(ten order by stt, ten), '[]'::jsonb)
      into v_groups
    from material_groups;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'ten', p.ten, 'departmentId', p.department_id, 'boPhan', coalesce(d.ten, p.bo_phan)
      ) order by p.ten), '[]'::jsonb)
      into v_props
    from proposers p
    left join departments d on d.id = p.department_id
    where v_all
       or coalesce(d.ten, p.bo_phan) is null
       or (v_actor_bp is not null and normalize_text(coalesce(d.ten, p.bo_phan)) = normalize_text(v_actor_bp));

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
  end if;

  return jsonb_build_object(
    'ok', true,
    'groups', v_groups,
    'departments', v_depts,
    'proposers', v_props,
    'materials', v_materials,
    'suppliers', v_suppliers,
    'canCreate', has_permission(v_actor.role, 'catalog:create'),
    'canManage', has_permission(v_actor.role, 'catalog:manage'),
    'canManageDepartments', has_permission(v_actor.role, 'department:manage')
  );
end;
$$;

-- ---- Receipt update: creator only; notify KTTH, not Admin ------------------
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
    cho_bo_sung = false,
    ly_do_bo_sung = null,
    nghiem_thu_at = now(),
    nghiem_thu_by = v_actor.id,
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
  where role = 'KeToanCongNo'
    and status = 'Hoạt động';

  perform write_audit(v_actor, 'ACCEPT_RECEIPT', 'debts', v_ma_cn, to_jsonb(v_before), to_jsonb(v_after), 'OK', 'Chờ kế toán duyệt hồ sơ.');
  return jsonb_build_object('ok', true, 'maCN', v_ma_cn);
end;
$$;

-- ---- Payment read vs manual adjustment -------------------------------------
create or replace function rpc_list_payments(p_ma_doi_tuong text default null, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_can_sensitive boolean;
  v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),'');
  v_rows jsonb;
begin
  v_actor := require_permission('payment:read');
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

create or replace function rpc_list_open_debts(p_ma_doi_tuong text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_ma text := nullif(trim(coalesce(p_ma_doi_tuong,'')),'');
  v_rows jsonb;
begin
  perform require_permission('payment:adjust');
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
    from v_debts vd
    join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false
      and vd.so_tien_con_lai > 0
      and vd.la_cong_no
      and (v_ma is null or dt.ma_doi_tuong = v_ma)
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_record_debt_payment(
  p_ma_cn text,
  p_so_tien numeric,
  p_ngay date default null,
  p_chung_tu text default null,
  p_ghi_chu text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_debt debts;
  v_pay uuid;
  v_ngay date;
  v_ma_tt text;
begin
  v_actor := require_permission('payment:adjust');
  if p_so_tien is null or p_so_tien <= 0 then
    raise exception 'Số tiền đã trả phải lớn hơn 0.';
  end if;

  select * into v_debt
  from debts
  where ma_cn = trim(coalesce(p_ma_cn,''))
    and is_archived = false;
  if v_debt is null then
    raise exception 'Không tìm thấy khoản công nợ %.', p_ma_cn;
  end if;

  if exists (select 1 from payment_request_lines l where l.debt_id = v_debt.id and l.paid) then
    raise exception 'Khoản % đã được thủ quỹ chi — không ghi thủ công (tránh trừ công nợ hai lần). Nếu cần điều chỉnh, hủy khoản chi ở lịch sử rồi ghi lại.', v_debt.ma_cn;
  end if;

  v_ngay := coalesce(p_ngay, current_date);
  v_ma_tt := next_code('TT');
  insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai)
  values (v_ma_tt, v_ngay, v_debt.doi_tuong_id, v_debt.ten_doi_tuong, p_so_tien, 'MA_CN', v_debt.ma_cn, p_chung_tu, p_ghi_chu, v_actor.id, 'Đã ghi nhận')
  returning id into v_pay;

  insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
  values (v_pay, v_debt.id, v_debt.ma_cn, p_so_tien);

  update debts
  set da_thanh_toan = da_thanh_toan + p_so_tien,
      ngay_tt_cuoi = v_ngay
  where id = v_debt.id;

  perform write_audit(v_actor, 'RECORD_DEBT_PAYMENT', 'debts', v_debt.ma_cn, to_jsonb(v_debt), jsonb_build_object('soTien', p_so_tien, 'maTT', v_ma_tt), 'OK', '');
  return jsonb_build_object('ok', true, 'maCN', v_debt.ma_cn, 'maThanhToan', v_ma_tt);
end;
$$;

create or replace function rpc_delete_payment(p_ma_thanh_toan text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_pay payments;
  r record;
begin
  v_actor := require_permission('payment:adjust');
  select * into v_pay
  from payments
  where ma_thanh_toan = trim(coalesce(p_ma_thanh_toan,''));
  if v_pay is null then
    raise exception 'Không tìm thấy lần thanh toán %.', p_ma_thanh_toan;
  end if;

  for r in select * from payment_allocations where payment_id = v_pay.id loop
    if r.debt_id is not null then
      update debts
      set da_thanh_toan = greatest(da_thanh_toan - r.so_tien_phan_bo, 0),
          is_archived = false,
          archived_at = null,
          archived_by = null
      where id = r.debt_id;
    end if;
  end loop;

  delete from payment_allocations where payment_id = v_pay.id;
  delete from payments where id = v_pay.id;
  perform write_audit(v_actor, 'DELETE_PAYMENT', 'payments', p_ma_thanh_toan, to_jsonb(v_pay), null, 'OK', 'Hủy khoản chi ghi nhầm.');
  return jsonb_build_object('ok', true, 'maThanhToan', p_ma_thanh_toan);
end;
$$;

-- ---- Debt dashboard: keep screen, scope rows by actor visibility ------------
create or replace function rpc_get_debt_dashboard(p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_from date := (p_filter->>'fromDate')::date;
  v_to date := (p_filter->>'toDate')::date;
  v_ma text := nullif(trim(coalesce(p_filter->>'maDoiTuong', '')), '');
  v_status text := nullif(trim(coalesce(p_filter->>'status', '')), '');
  v_summary jsonb;
  v_totals jsonb;
begin
  v_actor := require_permission('dashboard:read');

  with rows as (
    select vd.*, dt.ma_doi_tuong
    from v_debts vd
    join debts d on d.id = vd.id
    join doi_tuong dt on dt.id = vd.doi_tuong_id
    where vd.is_archived = false
      and vd.la_cong_no
      and (vd.thanh_tien_thuc_nhan <> 0 or vd.da_thanh_toan <> 0)
      and app_can_view_debt_record(d, v_actor)
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

-- ---- Recent/list exports ---------------------------------------------------
create or replace function rpc_get_recent(p_kind text default 'proposal', p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_limit int := least(greatest(coalesce((p_filter->>'limit')::int, 20), 1), 100);
  v_ma text := nullif(trim(coalesce(p_filter->>'maDoiTuong', '')), '');
  v_status text := nullif(trim(coalesce(p_filter->>'status', '')), '');
  v_from date := (p_filter->>'fromDate')::date;
  v_to date := (p_filter->>'toDate')::date;
  v_rows jsonb;
  v_columns jsonb;
begin
  if p_kind = 'payment' then
    v_actor := require_permission('payment:read');
  else
    v_actor := require_permission('recent:read');
  end if;

  if p_kind = 'payment' then
    v_columns := to_jsonb(array['MaThanhToan','NgayThanhToan','MaDoiTuong','TenDoiTuong','SoTien','PhanBoMode','MaCN','ChungTu','TrangThai']);
    select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb) into v_rows from (
      select p.created_at, jsonb_build_object(
        'MaThanhToan', p.ma_thanh_toan,
        'NgayThanhToan', to_char(p.ngay_thanh_toan, 'YYYY-MM-DD'),
        'MaDoiTuong', dt.ma_doi_tuong,
        'TenDoiTuong', p.ten_doi_tuong,
        'SoTien', p.so_tien,
        'PhanBoMode', p.phan_bo_mode,
        'MaCN', p.ma_cn,
        'ChungTu', p.chung_tu,
        'TrangThai', p.trang_thai
      ) as x
      from payments p left join doi_tuong dt on dt.id = p.doi_tuong_id
      where (v_ma is null or dt.ma_doi_tuong = v_ma)
        and (v_from is null or p.ngay_thanh_toan >= v_from)
        and (v_to is null or p.ngay_thanh_toan <= v_to)
      order by p.created_at desc
      limit v_limit
    ) t;

  elsif p_kind in ('receipt', 'debt', 'approved') then
    v_columns := to_jsonb(array['MaCN','MaDoiTuong','TenDoiTuong','MatHang','SLDat','SLThucNhan','ThanhTienThucNhan','DaThanhToan','TrangThai']);
    select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb) into v_rows from (
      select vd.created_at, jsonb_build_object(
        'MaCN', vd.ma_cn,
        'MaDoiTuong', dt.ma_doi_tuong,
        'TenDoiTuong', vd.ten_doi_tuong,
        'MatHang', vd.mat_hang,
        'SLDat', vd.sl_dat,
        'SLThucNhan', vd.sl_thuc_nhan,
        'ThanhTienThucNhan', vd.thanh_tien_thuc_nhan,
        'DaThanhToan', vd.da_thanh_toan,
        'TrangThai', vd.trang_thai_dong
      ) as x
      from v_debts vd
      join debts d on d.id = vd.id
      left join doi_tuong dt on dt.id = vd.doi_tuong_id
      where (p_kind <> 'receipt' or vd.is_archived = false)
        and app_can_view_debt_record(d, v_actor)
        and (v_ma is null or dt.ma_doi_tuong = v_ma)
        and (v_status is null or vd.trang_thai_dong ilike '%' || v_status || '%')
        and (v_from is null or coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) >= v_from)
        and (v_to is null or coalesce(vd.ngay_nhan, vd.ngay_duyet, vd.ngay_de_xuat) <= v_to)
      order by vd.created_at desc
      limit v_limit
    ) t;

  else
    v_columns := to_jsonb(array['MaDeXuat','NgayDeXuat','MaDoiTuong','TenDoiTuong','NoiDung','DieuKhoanTT','TrangThai','NguoiTao']);
    select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb) into v_rows from (
      select p.created_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat,
        'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'MaDoiTuong', dt.ma_doi_tuong,
        'TenDoiTuong', p.ten_doi_tuong,
        'NoiDung', p.noi_dung,
        'DieuKhoanTT', p.dieu_khoan_tt,
        'TrangThai', p.trang_thai,
        'NguoiTao', (select pr.name from profiles pr where pr.id = p.nguoi_tao)
      ) as x
      from proposals p
      left join doi_tuong dt on dt.id = p.doi_tuong_id
      where app_can_list_proposal(p, v_actor)
        and (v_ma is null or dt.ma_doi_tuong = v_ma)
        and (v_status is null or p.trang_thai ilike '%' || v_status || '%')
        and (v_from is null or p.ngay_de_xuat >= v_from)
        and (v_to is null or p.ngay_de_xuat <= v_to)
      order by p.created_at desc
      limit v_limit
    ) t;
  end if;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'rows', v_rows, 'columns', v_columns);
end;
$$;

create or replace function rpc_export_payment_requests(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('payment:request:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày', r->>'Mã ĐXTT'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Mã ĐXTT', pr.ma_de_xuat_tt,
      'Ngày', to_char(pr.ngay,'YYYY-MM-DD'),
      'Người lập', (select name from profiles where id=pr.nguoi_lap),
      'Trạng thái', pr.trang_thai,
      'Ngày duyệt', to_char(pr.approved_at,'YYYY-MM-DD'),
      'Nhà cung cấp', l.ncc,
      'Kế hoạch', l.ke_hoach,
      'Số tiền đề xuất', l.so_tien,
      'Nội dung', l.noi_dung,
      'Hình thức TT', l.hinh_thuc_tt,
      'Tình trạng hồ sơ', l.tinh_trang_ho_so,
      'Nối công nợ', case when l.debt_id is not null then 'Có' else 'Không' end
    ) as r
    from payment_requests pr
    join payment_request_lines l on l.request_id = pr.id
    where (p_from is null or pr.ngay >= p_from)
      and (p_to is null or pr.ngay <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_export_quotes(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('quote:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Ngày', to_char(q.ngay,'YYYY-MM-DD'),
      'Mặt hàng', q.mat_hang,
      'Nhà cung cấp', q.ncc,
      'ĐVT', q.dvt,
      'Giá gọi', q.gia,
      'VAT', q.vat_status,
      'Đề xuất', q.de_xuat,
      'Ghi chú', q.ghi_chu,
      'Nguồn', q.nguon
    ) as r
    from price_quotes q
    where (p_from is null or q.ngay >= p_from)
      and (p_to is null or q.ngay <= p_to)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- ---- Leadership dashboard: separate from normal debt dashboard --------------
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
  v_actor := require_permission('leaderdash:read');
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

-- ---- Private storage: keep evidence rules narrow after 0065 ----------------
create or replace function can_insert_business_attachment(p_object_name text) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_owner text;
  v_kind text;
begin
  select * into v_actor from profiles where id = auth.uid() and status = 'Hoạt động';
  if v_actor is null then
    return false;
  end if;

  v_owner := split_part(coalesce(p_object_name, ''), '/', 1);
  v_kind := split_part(coalesce(p_object_name, ''), '/', 2);
  return v_owner = v_actor.id::text
     and (
       (v_kind = 'bao-gia' and has_permission(v_actor.role, 'proposal:create'))
       or (v_kind = 'nghiem-thu' and has_permission(v_actor.role, 'receipt:update'))
       or (v_kind = 'chi-tien' and has_permission(v_actor.role, 'payment:execute'))
     );
end;
$$;

create or replace function can_read_business_attachment(p_object_name text) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
begin
  select * into v_actor from profiles where id = auth.uid() and status = 'Hoạt động';
  if v_actor is null or nullif(trim(coalesce(p_object_name, '')), '') is null then
    return false;
  end if;

  if exists (
    select 1
    from proposals p
    where business_attachment_json_has_path(p.attachments, p_object_name)
      and app_can_view_proposal(p, v_actor)
  ) then
    return true;
  end if;

  if exists (
    select 1
    from debts d
    left join proposals p on p.id = d.proposal_id
    where business_attachment_json_has_path(d.nghiem_thu_files, p_object_name)
      and (
        app_can_view_debt_evidence(d, v_actor)
        or (
          v_actor.role in ('ChuTich', 'TongGiamDoc', 'LanhDao')
          and exists (
            select 1
            from payment_request_lines l
            join payment_requests pr on pr.id = l.request_id
            where l.debt_id = d.id
              and pr.trang_thai in ('Chờ duyệt', 'Đã duyệt', 'Đã chi')
          )
        )
      )
  ) then
    return true;
  end if;

  if exists (
    select 1
    from payment_request_lines l
    left join debts d on d.id = l.debt_id
    left join proposals p on p.id = d.proposal_id
    where business_attachment_json_has_path(l.proof_files, p_object_name)
      and (
        v_actor.role in ('ThuQuy', 'KeToanCongNo', 'ChuTich', 'TongGiamDoc', 'LanhDao')
        or (l.paid = true and p.nguoi_tao = v_actor.id)
      )
  ) then
    return true;
  end if;

  if exists (
    select 1
    from payments pm
    left join debts d on d.ma_cn = pm.ma_cn
    left join proposals p on p.id = d.proposal_id
    where business_attachment_json_has_path(pm.proof_files, p_object_name)
      and (
        v_actor.role in ('ThuQuy', 'KeToanCongNo', 'ChuTich', 'TongGiamDoc', 'LanhDao')
        or p.nguoi_tao = v_actor.id
      )
  ) then
    return true;
  end if;

  return false;
end;
$$;

grant execute on function rpc_bootstrap() to authenticated;
grant execute on function rpc_add_department(text) to authenticated;
grant execute on function rpc_admin_list_users() to authenticated;
grant execute on function rpc_list_catalog() to authenticated;
grant execute on function rpc_update_receipt(jsonb) to authenticated;
grant execute on function rpc_list_payments(text, int) to authenticated;
grant execute on function rpc_list_open_debts(text) to authenticated;
grant execute on function rpc_record_debt_payment(text, numeric, date, text, text) to authenticated;
grant execute on function rpc_delete_payment(text) to authenticated;
grant execute on function rpc_get_debt_dashboard(jsonb) to authenticated;
grant execute on function rpc_get_recent(text, jsonb) to authenticated;
grant execute on function rpc_export_payment_requests(date, date) to authenticated;
grant execute on function rpc_export_quotes(date, date) to authenticated;
grant execute on function rpc_leader_dashboard(date, date) to authenticated;
grant execute on function can_insert_business_attachment(text) to authenticated;
grant execute on function can_read_business_attachment(text) to authenticated;
