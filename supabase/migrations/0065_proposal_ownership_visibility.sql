-- ============================================================================
-- 0065_proposal_ownership_visibility.sql
--  Protect proposal ownership and department-scoped visibility at the RPC layer.
--
--  Rules:
--    * Purchasing staff only view/edit/submit/withdraw their own proposals.
--    * Department heads only see submitted proposals from their own department.
--    * KTTH / leadership shared views do not expose unsubmitted drafts.
--    * Admin can inspect any proposal directly, while shared list APIs still
--      avoid sending drafts unless they are the caller's own.
--    * Department checks prefer hidden department_id and use bo_phan as a
--      legacy fallback.
-- ============================================================================

alter table profiles add column if not exists department_id uuid references departments (id);
alter table proposals add column if not exists department_id uuid references departments (id);

create index if not exists idx_profiles_department_id on profiles (department_id);
create index if not exists idx_proposals_department_id on proposals (department_id);
create index if not exists idx_proposals_department_status on proposals (department_id, trang_thai);

alter table proposals drop constraint if exists proposals_trang_thai_check;
alter table proposals add constraint proposals_trang_thai_check
  check (trang_thai in ('Nháp','Chờ duyệt','Đã duyệt','Từ chối','Đã hủy'));

insert into departments (ten)
select distinct trim(bo_phan)
from profiles
where nullif(trim(coalesce(bo_phan,'')), '') is not null
on conflict (ten) do nothing;

insert into departments (ten)
select distinct trim(bo_phan)
from proposals
where nullif(trim(coalesce(bo_phan,'')), '') is not null
on conflict (ten) do nothing;

update profiles p
set department_id = d.id
from departments d
where p.department_id is null
  and nullif(trim(coalesce(p.bo_phan,'')), '') is not null
  and normalize_text(d.ten) = normalize_text(p.bo_phan);

update proposals p
set department_id = d.id
from departments d
where p.department_id is null
  and nullif(trim(coalesce(p.bo_phan,'')), '') is not null
  and normalize_text(d.ten) = normalize_text(p.bo_phan);

create or replace function app_department_id_from_name(p_name text) returns uuid
language sql stable as $$
  select d.id
  from departments d
  where normalize_text(d.ten) = normalize_text(nullif(trim(coalesce(p_name,'')), ''))
  order by d.created_at, d.ten
  limit 1;
$$;

create or replace function app_ensure_department_id(p_name text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_name text := nullif(trim(coalesce(p_name,'')), '');
  v_id uuid;
begin
  if v_name is null then
    return null;
  end if;

  select app_department_id_from_name(v_name) into v_id;
  if v_id is not null then
    return v_id;
  end if;

  insert into departments (ten) values (v_name)
  on conflict (ten) do update set ten = excluded.ten
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function trg_sync_profile_department() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'UPDATE' and new.department_id is distinct from old.department_id then
    if new.department_id is not null then
      select ten into new.bo_phan from departments where id = new.department_id;
    elsif nullif(trim(coalesce(new.bo_phan,'')), '') is not null then
      new.department_id := app_ensure_department_id(new.bo_phan);
      select ten into new.bo_phan from departments where id = new.department_id;
    end if;
  elsif TG_OP = 'UPDATE' and new.bo_phan is distinct from old.bo_phan then
    if nullif(trim(coalesce(new.bo_phan,'')), '') is null then
      new.department_id := null;
    else
      new.department_id := app_ensure_department_id(new.bo_phan);
      select ten into new.bo_phan from departments where id = new.department_id;
    end if;
  elsif new.department_id is not null then
    select ten into new.bo_phan from departments where id = new.department_id;
  elsif nullif(trim(coalesce(new.bo_phan,'')), '') is not null then
    new.department_id := app_ensure_department_id(new.bo_phan);
    select ten into new.bo_phan from departments where id = new.department_id;
  end if;
  return new;
end;
$$;

drop trigger if exists t_sync_profile_department on profiles;
create trigger t_sync_profile_department
before insert or update of bo_phan, department_id on profiles
for each row execute function trg_sync_profile_department();

create or replace function trg_sync_proposal_department() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'UPDATE' and new.department_id is distinct from old.department_id then
    if new.department_id is not null then
      select ten into new.bo_phan from departments where id = new.department_id;
    elsif nullif(trim(coalesce(new.bo_phan,'')), '') is not null then
      new.department_id := app_ensure_department_id(new.bo_phan);
      select ten into new.bo_phan from departments where id = new.department_id;
    end if;
  elsif TG_OP = 'UPDATE' and new.bo_phan is distinct from old.bo_phan then
    if nullif(trim(coalesce(new.bo_phan,'')), '') is null then
      new.department_id := null;
    else
      new.department_id := app_ensure_department_id(new.bo_phan);
      select ten into new.bo_phan from departments where id = new.department_id;
    end if;
  elsif new.department_id is not null then
    select ten into new.bo_phan from departments where id = new.department_id;
  elsif nullif(trim(coalesce(new.bo_phan,'')), '') is not null then
    new.department_id := app_ensure_department_id(new.bo_phan);
    select ten into new.bo_phan from departments where id = new.department_id;
  end if;
  return new;
end;
$$;

drop trigger if exists t_sync_proposal_department on proposals;
create trigger t_sync_proposal_department
before insert or update of bo_phan, department_id on proposals
for each row execute function trg_sync_proposal_department();

create or replace function app_profile_department_id(p_profile profiles) returns uuid
language sql stable as $$
  select coalesce(p_profile.department_id, app_department_id_from_name(p_profile.bo_phan));
$$;

create or replace function app_proposal_department_id(p_proposal proposals) returns uuid
language sql stable as $$
  select coalesce(p_proposal.department_id, app_department_id_from_name(p_proposal.bo_phan));
$$;

create or replace function app_profile_department_name(p_profile profiles) returns text
language sql stable as $$
  select coalesce(
    (select d.ten from departments d where d.id = app_profile_department_id(p_profile)),
    nullif(trim(coalesce(p_profile.bo_phan,'')), '')
  );
$$;

create or replace function app_same_department(p_proposal proposals, p_actor profiles) returns boolean
language plpgsql stable as $$
declare
  v_proposal_department_id uuid := app_proposal_department_id(p_proposal);
  v_actor_department_id uuid := app_profile_department_id(p_actor);
begin
  if p_proposal.department_id is not null and p_actor.department_id is not null then
    return p_proposal.department_id = p_actor.department_id;
  end if;

  if v_proposal_department_id is not null and v_actor_department_id is not null then
    return v_proposal_department_id = v_actor_department_id;
  end if;

  return nullif(trim(coalesce(p_proposal.bo_phan,'')), '') is not null
     and nullif(trim(coalesce(p_actor.bo_phan,'')), '') is not null
     and normalize_text(p_proposal.bo_phan) = normalize_text(p_actor.bo_phan);
end;
$$;

create or replace function app_can_view_proposal(p_proposal proposals, p_actor profiles) returns boolean
language plpgsql stable as $$
begin
  if p_actor.role = 'Admin' then
    return true;
  end if;

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

  if p_actor.role = 'Admin' then
    return true;
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

  if p_actor.role in ('Admin','KeToanCongNo') then
    return true;
  end if;

  if p_actor.role = 'TruongPhong' then
    return app_same_department(p_proposal, p_actor);
  end if;

  return false;
end;
$$;

create or replace function app_actor_proposal_department(p_actor profiles, p_payload jsonb default '{}'::jsonb)
returns table (department_id uuid, bo_phan text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_payload_bo_phan text := nullif(trim(coalesce(p_payload->>'boPhan','')), '');
begin
  if p_actor.role = 'Admin' and v_payload_bo_phan is not null then
    department_id := app_ensure_department_id(v_payload_bo_phan);
    bo_phan := (select ten from departments where id = department_id);
    return next;
    return;
  end if;

  department_id := app_profile_department_id(p_actor);
  bo_phan := app_profile_department_name(p_actor);

  if department_id is null and bo_phan is not null then
    department_id := app_ensure_department_id(bo_phan);
    bo_phan := (select ten from departments where id = department_id);
  end if;

  if department_id is null and p_actor.role in ('NhanVienMuaHang','TruongPhong') then
    raise exception 'Tài khoản chưa được gán bộ phận. Hãy liên hệ Admin để cập nhật hồ sơ.';
  end if;

  return next;
end;
$$;

-- ---- Proposal create/update/get/submit/withdraw ----------------------------

create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status','Nháp')='Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_loai text := case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end;
  v_in_plan boolean := coalesce((p_payload->>'trongKeHoachTuan')::boolean,false);
  v_giai_trinh text := nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),'');
  v_actor profiles;
  v_dept record;
  v_dt doi_tuong;
  v_ma text;
  v_pid uuid;
  v_line jsonb;
  v_qty numeric;
  v_price numeric;
  v_vat numeric;
  v_n int := 0;
  v_h jsonb;
begin
  v_actor := require_permission(case when v_status='Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);
  select * into v_dept from app_actor_proposal_department(v_actor, p_payload);

  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines')=0 then
    raise exception 'Đề xuất cần ít nhất một dòng vật tư.';
  end if;
  if v_status='Chờ duyệt' and not v_in_plan and v_giai_trinh is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.';
  end if;
  if v_status='Chờ duyệt' and v_loai='MuaHang' and jsonb_array_length(p_payload->'lines') >= 2
     and coalesce(jsonb_array_length(p_payload->'attachments'),0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;

  v_dt := ensure_doi_tuong(
    p_payload->'doiTuong'->>'ma',
    p_payload->'doiTuong'->>'ten',
    coalesce(p_payload->'doiTuong'->>'loai','NCC'),
    p_payload->'doiTuong'->>'mst',
    p_payload->'doiTuong'->>'diaChi',
    p_payload->'doiTuong'->>'contact',
    coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT')
  );

  v_ma := next_code('DX');
  insert into proposals (
    ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, bo_phan, department_id,
    doi_tuong_id, ten_doi_tuong, noi_dung, dieu_khoan_tt, trang_thai,
    nguoi_tao, ghi_chu, loai_de_xuat, trong_ke_hoach_tuan,
    giai_trinh_ngoai_ke_hoach, han_thanh_toan, ton_kho, truong_bp_duyet,
    prepay, prepay_percent, attachments
  )
  values (
    v_ma,
    coalesce((p_payload->>'ngayDeXuat')::date, current_date),
    coalesce(nullif(trim(coalesce(p_payload->>'nguoiDeNghi','')), ''), v_actor.name),
    v_dept.bo_phan,
    v_dept.department_id,
    v_dt.id,
    v_dt.ten_doi_tuong,
    p_payload->>'noiDung',
    coalesce(p_payload->>'dieuKhoanTT', v_dt.dieu_khoan_tt_mac_dinh),
    v_status,
    v_actor.id,
    p_payload->>'ghiChu',
    v_loai,
    v_in_plan,
    v_giai_trinh,
    (p_payload->>'hanThanhToan')::date,
    parse_number(p_payload->>'tonKho'),
    coalesce((p_payload->>'truongBpDuyet')::boolean,false),
    coalesce((p_payload->>'prepay')::boolean,false),
    parse_number(p_payload->>'prepayPercent'),
    coalesce(p_payload->'attachments','[]'::jsonb)
  )
  returning id into v_pid;

  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat');
    v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then
      continue;
    end if;
    v_vat := parse_vat_rate(v_line->>'vat');
    perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (
      ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat,
      vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai
    )
    values (
      next_code('DXL'), v_pid, trim(v_line->>'matHang'), v_qty, v_price,
      v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', v_status
    );
    v_n := v_n + 1;
  end loop;

  if v_n=0 then
    raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.';
  end if;

  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai) into v_h
  from proposals
  where id=v_pid;
  perform write_audit(v_actor,'CREATE_PROPOSAL','proposals',v_ma,null,v_h,'OK',v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma, 'status', v_status);
end;
$$;

create or replace function rpc_update_proposal(p_ma_de_xuat text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
  v_dept record;
  v_dt doi_tuong;
  v_line jsonb;
  v_qty numeric;
  v_price numeric;
  v_vat numeric;
  v_n int := 0;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất.';
  end if;
  if v_p.nguoi_tao is distinct from v_actor.id and v_actor.role <> 'Admin' then
    raise exception 'Bạn chỉ được sửa đề xuất do mình tạo.';
  end if;
  if v_p.trang_thai <> 'Nháp' then
    raise exception 'Chỉ sửa được phiếu Nháp.';
  end if;

  select * into v_dept from app_actor_proposal_department(v_actor, p_payload);
  v_dt := ensure_doi_tuong(
    null,
    p_payload->'doiTuong'->>'ten',
    'NCC',
    null,
    null,
    null,
    coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT')
  );

  update proposals set
    loai_de_xuat = case when coalesce(p_payload->>'loaiDeXuat','MuaHang')='TamUng' then 'TamUng' else 'MuaHang' end,
    ngay_de_xuat = coalesce((p_payload->>'ngayDeXuat')::date, ngay_de_xuat),
    nguoi_de_nghi = coalesce(nullif(trim(coalesce(p_payload->>'nguoiDeNghi','')), ''), nguoi_de_nghi),
    bo_phan = v_dept.bo_phan,
    department_id = v_dept.department_id,
    doi_tuong_id = v_dt.id,
    ten_doi_tuong = v_dt.ten_doi_tuong,
    noi_dung = p_payload->>'noiDung',
    dieu_khoan_tt = coalesce(p_payload->>'dieuKhoanTT', dieu_khoan_tt),
    han_thanh_toan = (p_payload->>'hanThanhToan')::date,
    ton_kho = parse_number(p_payload->>'tonKho'),
    truong_bp_duyet = coalesce((p_payload->>'truongBpDuyet')::boolean,false),
    prepay = coalesce((p_payload->>'prepay')::boolean,false),
    prepay_percent = parse_number(p_payload->>'prepayPercent'),
    trong_ke_hoach_tuan = coalesce((p_payload->>'trongKeHoachTuan')::boolean,false),
    giai_trinh_ngoai_ke_hoach = nullif(trim(coalesce(p_payload->>'giaiTrinhNgoaiKeHoach','')),''),
    attachments = case
      when p_payload ? 'attachments' and jsonb_array_length(p_payload->'attachments')>0 then p_payload->'attachments'
      else attachments
    end
  where id = v_p.id;

  delete from proposal_lines where proposal_id = v_p.id;
  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_qty := parse_number(v_line->>'slDat');
    v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'),'')='' or v_qty is null or v_price is null then
      continue;
    end if;
    v_vat := parse_vat_rate(v_line->>'vat');
    perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (
      ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat,
      vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai
    )
    values (
      next_code('DXL'), v_p.id, trim(v_line->>'matHang'), v_qty, v_price,
      v_vat, round(v_qty*v_price*(1+v_vat),2), v_line->>'ghiChu', 'Nháp'
    );
    v_n := v_n + 1;
  end loop;

  if v_n=0 then
    raise exception 'Đề xuất cần ít nhất một dòng hợp lệ.';
  end if;

  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

create or replace function rpc_get_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
  v_j jsonb;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất.';
  end if;
  if v_p.nguoi_tao is distinct from v_actor.id and v_actor.role <> 'Admin' then
    raise exception 'Bạn chỉ được mở đề xuất do mình tạo.';
  end if;
  if v_p.trang_thai <> 'Nháp' then
    raise exception 'Chỉ mở phiếu Nháp để sửa.';
  end if;

  select jsonb_build_object(
    'MaDeXuat', v_p.ma_de_xuat,
    'TrangThai', v_p.trang_thai,
    'LoaiDeXuat', v_p.loai_de_xuat,
    'NgayDeXuat', to_char(v_p.ngay_de_xuat,'YYYY-MM-DD'),
    'NguoiDeNghi', v_p.nguoi_de_nghi,
    'BoPhan', v_p.bo_phan,
    'TenDoiTuong', v_p.ten_doi_tuong,
    'DieuKhoanTT', v_p.dieu_khoan_tt,
    'HanThanhToan', to_char(v_p.han_thanh_toan,'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho,
    'TruongBpDuyet', v_p.truong_bp_duyet,
    'Prepay', v_p.prepay,
    'PrepayPercent', v_p.prepay_percent,
    'LyDoTraLai', v_p.ly_do_tra_lai,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan,
    'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach,
    'Attachments', v_p.attachments,
    'lines', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'matHang', l.mat_hang,
        'slDat', l.sl_dat,
        'donGia', l.don_gia_chua_vat,
        'vat', (l.vat_rate*100)||'%',
        'ghiChu', l.ghi_chu
      ) order by l.ma_line),'[]'::jsonb)
      from proposal_lines l
      where l.proposal_id = v_p.id
    )
  ) into v_j;

  return jsonb_build_object('ok', true, 'proposal', v_j);
end;
$$;

create or replace function rpc_submit_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
  v_dept record;
begin
  v_actor := require_permission('proposal:submit');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if v_p.nguoi_tao is distinct from v_actor.id and v_actor.role <> 'Admin' then
    raise exception 'Bạn chỉ được gửi duyệt đề xuất do mình tạo.';
  end if;
  if v_p.trang_thai <> 'Nháp' then
    raise exception 'Chỉ gửi duyệt được phiếu đang ở trạng thái Nháp.';
  end if;
  select * into v_dept from app_actor_proposal_department(v_actor, '{}'::jsonb);
  if not v_p.trong_ke_hoach_tuan and nullif(trim(coalesce(v_p.giai_trinh_ngoai_ke_hoach,'')),'') is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.';
  end if;
  if v_p.loai_de_xuat = 'MuaHang'
     and (select count(*) from proposal_lines where proposal_id = v_p.id) >= 2
     and coalesce(jsonb_array_length(v_p.attachments), 0) < 2 then
    raise exception 'Phiếu có từ 2 mặt hàng trở lên cần ít nhất 2 báo giá đính kèm.';
  end if;

  update proposals
  set trang_thai = 'Chờ duyệt',
      ly_do_tra_lai = null,
      bo_phan = coalesce(v_dept.bo_phan, bo_phan),
      department_id = coalesce(v_dept.department_id, department_id)
  where id = v_p.id;

  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

create or replace function rpc_withdraw_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
begin
  v_actor := require_permission('proposal:create');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if v_p.nguoi_tao is distinct from v_actor.id and v_actor.role <> 'Admin' then
    raise exception 'Chỉ người tạo phiếu hoặc Admin mới được rút.';
  end if;
  if v_p.trang_thai not in ('Nháp','Chờ duyệt','Đã duyệt') then
    raise exception 'Chỉ rút được phiếu chưa phát sinh thanh toán (hiện: %).', v_p.trang_thai;
  end if;
  if exists (
    select 1
    from debts d
    where d.proposal_id = v_p.id
      and (d.da_thanh_toan > 0 or exists (select 1 from payment_request_lines l where l.debt_id = d.id))
  ) then
    raise exception 'Đã phát sinh đề xuất/khoản thanh toán — không thể rút.';
  end if;

  update proposal_lines set debt_id = null where proposal_id = v_p.id;
  delete from debts where proposal_id = v_p.id;
  update proposals
  set trang_thai = 'Đã hủy',
      ghi_chu = coalesce(ghi_chu||' | ','') || 'Rút: ' || coalesce(nullif(trim(coalesce(p_reason,'')),''),'người tạo rút')
  where id = v_p.id;

  perform write_audit(
    v_actor,
    'WITHDRAW_PROPOSAL',
    'proposals',
    p_ma_de_xuat,
    to_jsonb(v_p),
    jsonb_build_object('reason', p_reason),
    'OK',
    'Rút đề xuất mua hàng.'
  );
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

-- ---- Shared proposal detail / oversight -----------------------------------

create or replace function app_proposal_detail_json(p_proposal proposals) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'MaDeXuat', p_proposal.ma_de_xuat,
    'LoaiDeXuat', p_proposal.loai_de_xuat,
    'TrangThai', p_proposal.trang_thai,
    'BoPhan', p_proposal.bo_phan,
    'NguoiDeNghi', p_proposal.nguoi_de_nghi,
    'NguoiTao', (select name from profiles where id = p_proposal.nguoi_tao),
    'TenDoiTuong', p_proposal.ten_doi_tuong,
    'DieuKhoanTT', p_proposal.dieu_khoan_tt,
    'HanThanhToan', to_char(p_proposal.han_thanh_toan, 'YYYY-MM-DD'),
    'TonKho', p_proposal.ton_kho,
    'TruongBpDuyet', p_proposal.truong_bp_duyet,
    'Prepay', p_proposal.prepay,
    'PrepayPercent', p_proposal.prepay_percent,
    'TrongKeHoachTuan', p_proposal.trong_ke_hoach_tuan,
    'GiaiTrinhNgoaiKeHoach', p_proposal.giai_trinh_ngoai_ke_hoach,
    'NoiDung', p_proposal.noi_dung,
    'GhiChu', p_proposal.ghi_chu,
    'LyDoTraLai', p_proposal.ly_do_tra_lai,
    'Attachments', coalesce(p_proposal.attachments, '[]'::jsonb),
    'ThoiGianTao', to_char(p_proposal.created_at, 'YYYY-MM-DD HH24:MI'),
    'ThoiGianDuyet', to_char(p_proposal.approved_at, 'YYYY-MM-DD HH24:MI'),
    'NguoiDuyet', (select name from profiles where id = p_proposal.nguoi_duyet),
    'DaNghiemThu', exists(select 1 from debts d where d.proposal_id = p_proposal.id and d.sl_thuc_nhan is not null),
    'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id = p_proposal.id and d.da_thanh_toan > 0),
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines where proposal_id = p_proposal.id), 0),
    'lines', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'MatHang', l.mat_hang,
        'SLDat', l.sl_dat,
        'DonGiaChuaVAT', l.don_gia_chua_vat,
        'VATRate', l.vat_rate,
        'ThanhTienSauVAT', l.thanh_tien_sau_vat,
        'GhiChu', l.ghi_chu
      ) order by l.ma_line), '[]'::jsonb)
      from proposal_lines l
      where l.proposal_id = p_proposal.id
    )
  );
$$;

create or replace function rpc_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
begin
  v_actor := require_permission('recent:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if not app_can_view_proposal(v_p, v_actor) then
    raise exception 'Bạn không có quyền xem đề xuất này.';
  end if;

  return jsonb_build_object('ok', true, 'proposal', app_proposal_detail_json(v_p));
end;
$$;

create or replace function rpc_oversight(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_props jsonb;
  v_pays jsonb;
  v_tbp boolean;
begin
  v_actor := require_permission('oversight:read');
  v_tbp := (v_actor.role = 'TruongPhong');

  select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_props
  from (
    select jsonb_build_object(
      'MaDeXuat', p.ma_de_xuat,
      'Loai', case when p.loai_de_xuat='TamUng' then 'Tạm ứng' else 'Mua hàng' end,
      'Ngay', to_char(p.ngay_de_xuat,'YYYY-MM-DD'),
      'NguoiDeNghi', p.nguoi_de_nghi,
      'BoPhan', p.bo_phan,
      'TenDoiTuong', p.ten_doi_tuong,
      'TrangThai', p.trang_thai,
      'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'),
      'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id=p.id),0),
      'DaNghiemThu', exists(select 1 from debts d where d.proposal_id=p.id and d.sl_thuc_nhan is not null),
      'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id=p.id and d.da_thanh_toan>0),
      'ThoiGianTao', to_char(p.created_at,'YYYY-MM-DD HH24:MI'),
      'ThoiGianDuyet', to_char(p.approved_at,'YYYY-MM-DD HH24:MI'),
      'NguoiDuyet', (select name from profiles where id=p.nguoi_duyet)
    ) as x
    from proposals p
    where (p_from is null or p.ngay_de_xuat >= p_from)
      and (p_to is null or p.ngay_de_xuat <= p_to)
      and app_can_oversight_proposal(p, v_actor)
    order by p.ngay_de_xuat desc
    limit 500
  ) t;

  if v_tbp then
    v_pays := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_pays
    from (
      select jsonb_build_object(
        'MaDeXuatTT', pr.ma_de_xuat_tt,
        'Ngay', to_char(pr.ngay,'YYYY-MM-DD'),
        'TrangThai', pr.trang_thai,
        'NguoiLap', (select name from profiles where id=pr.nguoi_lap),
        'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id=pr.id),0)
      ) as x
      from payment_requests pr
      where (p_from is null or pr.ngay >= p_from)
        and (p_to is null or pr.ngay <= p_to)
      order by pr.ngay desc
      limit 500
    ) t;
  end if;

  return jsonb_build_object('ok', true, 'role', v_actor.role, 'proposals', v_props, 'paymentRequests', v_pays);
end;
$$;

create or replace function rpc_oversight_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
begin
  v_actor := require_permission('oversight:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if not app_can_oversight_proposal(v_p, v_actor) then
    raise exception 'Bạn không có quyền rà soát đề xuất này.';
  end if;

  return jsonb_build_object('ok', true, 'proposal', app_proposal_detail_json(v_p));
end;
$$;

create or replace function rpc_cancel_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
begin
  v_actor := require_permission('oversight:cancel');
  if nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'Cần nhập lý do hủy để báo người lập.';
  end if;
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if not app_can_oversight_proposal(v_p, v_actor) then
    raise exception 'Bạn không có quyền hủy đề xuất này.';
  end if;
  if v_p.trang_thai <> 'Chờ duyệt' then
    raise exception 'Chỉ hủy được phiếu đang CHỜ DUYỆT (trước khi sếp duyệt).';
  end if;

  update proposals
  set trang_thai = 'Từ chối',
      ghi_chu = coalesce(ghi_chu,'') || ' | HỦY (rà soát) bởi ' || coalesce(v_actor.name,'') || ': ' || trim(p_reason)
  where id = v_p.id;

  perform write_audit(v_actor, 'CANCEL_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_p), jsonb_build_object('reason', p_reason), 'OK', trim(p_reason));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

create or replace function rpc_bounce_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_p proposals;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_removed int := 0;
begin
  v_actor := require_permission('oversight:cancel');
  if v_reason is null then
    raise exception 'Cần nhập lý do trả lại để người lập giải trình.';
  end if;
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if not app_can_oversight_proposal(v_p, v_actor) then
    raise exception 'Bạn không có quyền trả lại đề xuất này.';
  end if;
  if v_p.trang_thai not in ('Chờ duyệt','Đã duyệt') then
    raise exception 'Chỉ trả lại được phiếu đang CHỜ DUYỆT hoặc ĐÃ DUYỆT (chưa thanh toán).';
  end if;

  if v_p.trang_thai = 'Đã duyệt' then
    if exists (select 1 from debts d where d.proposal_id = v_p.id and (d.da_thanh_toan > 0 or d.is_archived)) then
      raise exception 'Phiếu đã phát sinh thanh toán/đã tất toán — không thể trả lại. Hãy hủy khoản thanh toán trước.';
    end if;
    if exists (select 1 from payment_request_lines prl join debts d on d.id = prl.debt_id where d.proposal_id = v_p.id) then
      raise exception 'Công nợ của phiếu đang nằm trong một đề xuất thanh toán — hãy hủy đề xuất thanh toán đó trước.';
    end if;
    update proposal_lines set trang_thai = 'Nháp', debt_id = null where proposal_id = v_p.id;
    delete from debts where proposal_id = v_p.id;
    get diagnostics v_removed = row_count;
  end if;

  update proposals set
    trang_thai = 'Nháp',
    nguoi_duyet = null,
    approved_at = null,
    ly_do_tra_lai = v_reason,
    ghi_chu = coalesce(ghi_chu,'') || ' | TRẢ LẠI (rà soát) bởi ' || coalesce(v_actor.name,'') || ': ' || v_reason
  where id = v_p.id;

  if v_p.nguoi_tao is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (
      v_p.nguoi_tao,
      'proposal_bounced',
      'Đề xuất bị trả lại — cần giải trình',
      v_p.ma_de_xuat || ': ' || v_reason,
      'proposal',
      v_p.ma_de_xuat
    );
  end if;

  perform write_audit(
    v_actor,
    'BOUNCE_PROPOSAL',
    'proposals',
    p_ma_de_xuat,
    to_jsonb(v_p),
    jsonb_build_object('reason', v_reason, 'debtsRemoved', v_removed),
    'OK',
    v_reason
  );
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'debtsRemoved', v_removed);
end;
$$;

-- ---- Approval/detail history ----------------------------------------------

create or replace function rpc_approve_proposal(p_ma_de_xuat text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_proposal proposals;
  v_line proposal_lines;
  v_row_count int := 0;
  v_now date := current_date;
  v_new_debt_id uuid;
  v_total numeric;
  v_threshold numeric;
begin
  v_actor := require_permission('proposal:approve');

  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if v_proposal.trang_thai <> 'Chờ duyệt' then
    raise exception 'Chỉ duyệt được đề xuất đã gửi duyệt.';
  end if;

  select coalesce(sum(thanh_tien_sau_vat),0) into v_total
  from proposal_lines
  where proposal_id = v_proposal.id;
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold
  from app_config
  where key='approval_threshold';

  if v_actor.role not in ('Admin','ChuTich') and v_total >= v_threshold then
    raise exception 'Khoản % đ (≥ %) thuộc thẩm quyền CHỦ TỊCH.', to_char(v_total,'FM999,999,999'), to_char(v_threshold,'FM999,999,999');
  end if;

  for v_line in select * from proposal_lines where proposal_id = v_proposal.id loop
    insert into debts (
      ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong,
      loai_cong_no, proposal_id, ma_lo_hang, mat_hang, sl_dat, don_gia,
      vat_rate, dieu_khoan_tt, han_thanh_toan, prepay, ghi_chu, nguon_tao
    )
    values (
      next_code('CN'),
      v_proposal.ngay_de_xuat,
      v_now,
      v_proposal.doi_tuong_id,
      v_proposal.ten_doi_tuong,
      case when v_proposal.loai_de_xuat='TamUng' then 'TamUng' else 'AP' end,
      v_proposal.id,
      p_ma_de_xuat||'-'||lpad((v_row_count+1)::text,2,'0'),
      v_line.mat_hang,
      v_line.sl_dat,
      v_line.don_gia_chua_vat,
      v_line.vat_rate,
      v_proposal.dieu_khoan_tt,
      v_proposal.han_thanh_toan,
      v_proposal.prepay,
      format('WebApp | Nội dung: %s | Ghi chú: %s', coalesce(v_proposal.noi_dung,''), coalesce(v_line.ghi_chu,'')),
      'WebApp'
    )
    returning id into v_new_debt_id;

    v_row_count := v_row_count + 1;
    update proposal_lines set trang_thai='Đã duyệt', debt_id=v_new_debt_id where id=v_line.id;
  end loop;

  update proposals
  set trang_thai='Đã duyệt',
      nguoi_duyet=v_actor.id,
      approved_at=now(),
      ghi_chu = case
        when nullif(trim(coalesce(p_note,'')),'') is not null then coalesce(ghi_chu,'')||' | Duyệt: '||trim(p_note)
        else ghi_chu
      end
  where id=v_proposal.id;

  perform write_audit(
    v_actor,
    'APPROVE_PROPOSAL',
    'proposals',
    p_ma_de_xuat,
    to_jsonb(v_proposal),
    jsonb_build_object('rows',v_row_count,'total',v_total),
    'OK',
    coalesce(nullif(trim(p_note),''),'Đã duyệt.')
  );
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'congNoRows', v_row_count);
end;
$$;

create or replace function rpc_reject_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_proposal proposals;
begin
  v_actor := require_permission('proposal:reject');
  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if v_proposal.trang_thai <> 'Chờ duyệt' then
    raise exception 'Chỉ từ chối được đề xuất đã gửi duyệt.';
  end if;

  update proposals
  set trang_thai = 'Từ chối',
      nguoi_duyet = v_actor.id,
      approved_at = now(),
      ghi_chu = coalesce(p_reason, ghi_chu)
  where id = v_proposal.id;

  perform write_audit(v_actor, 'REJECT_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal), jsonb_build_object('reason', p_reason), 'OK', p_reason);
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

create or replace function rpc_get_approved_proposals(p_date date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_date date := coalesce(p_date, current_date);
  v_rows jsonb;
begin
  v_actor := require_permission('proposal:approve');
  select coalesce(jsonb_agg(row_data order by approved_at desc), '[]'::jsonb) into v_rows
  from (
    select p.approved_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat,
        'LoaiDeXuat', p.loai_de_xuat,
        'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD HH24:MI'),
        'TenDoiTuong', p.ten_doi_tuong,
        'NoiDung', p.noi_dung,
        'NguoiDeNghi', p.nguoi_de_nghi,
        'BoPhan', p.bo_phan,
        'TruongBpDuyet', p.truong_bp_duyet,
        'NguoiDuyet', (select name from profiles where id = p.nguoi_duyet),
        'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'),
        'Attachments', p.attachments,
        'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0),
        'DaPhatSinhTT', exists (
          select 1
          from debts d
          where d.proposal_id = p.id
            and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))
        ),
        'lines', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'MatHang', l.mat_hang,
            'SLDat', l.sl_dat,
            'DonGiaChuaVAT', l.don_gia_chua_vat,
            'VATRate', l.vat_rate,
            'ThanhTienSauVAT', l.thanh_tien_sau_vat,
            'GhiChu', l.ghi_chu
          ) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l
          where l.proposal_id = p.id
        )
      ) as row_data
    from proposals p
    where p.trang_thai = 'Đã duyệt'
      and p.approved_at is not null
      and (p.approved_at at time zone 'Asia/Ho_Chi_Minh')::date = v_date
      and app_can_view_proposal(p, v_actor)
    order by p.approved_at desc
  ) x;

  return jsonb_build_object('ok', true, 'date', to_char(v_date, 'YYYY-MM-DD'), 'rows', v_rows);
end;
$$;

-- ---- Recent/export proposal reads -----------------------------------------

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
  v_actor := require_permission('recent:read');

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
      left join doi_tuong dt on dt.id = vd.doi_tuong_id
      left join proposals pp on pp.id = vd.proposal_id
      where (p_kind <> 'receipt' or vd.is_archived = false)
        and (pp.id is null or app_can_list_proposal(pp, v_actor))
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

create or replace function rpc_export_proposals(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_rows jsonb;
begin
  v_actor := require_permission('recent:read');
  select coalesce(jsonb_agg(r order by r->>'Ngày đề xuất', r->>'Mã đề xuất'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'Mã đề xuất', p.ma_de_xuat,
      'Loại', case when p.loai_de_xuat='TamUng' then 'Tạm ứng' else 'Mua hàng' end,
      'Ngày đề xuất', to_char(p.ngay_de_xuat,'YYYY-MM-DD'),
      'Người đề nghị', p.nguoi_de_nghi,
      'Bộ phận', p.bo_phan,
      'Mã NCC', dt.ma_doi_tuong,
      'Nhà cung cấp', p.ten_doi_tuong,
      'Trong kế hoạch tuần', case when p.trong_ke_hoach_tuan then 'Có' else 'Không' end,
      'Mã vật tư', m.ma_vat_tu,
      'Nhóm hàng', m.nhom,
      'Mặt hàng', l.mat_hang,
      'SL đặt', l.sl_dat,
      'Đơn giá', l.don_gia_chua_vat,
      'VAT', l.vat_rate,
      'Thành tiền sau VAT', l.thanh_tien_sau_vat,
      'Trạng thái duyệt', p.trang_thai,
      'Ngày duyệt', to_char(p.approved_at,'YYYY-MM-DD'),
      'SL nghiệm thu', (select d.sl_thuc_nhan from debts d where d.proposal_id=p.id and d.mat_hang=l.mat_hang order by d.created_at limit 1),
      'Đã nghiệm thu', case when exists (select 1 from debts d where d.proposal_id=p.id and d.mat_hang=l.mat_hang and d.sl_thuc_nhan is not null) then 'Có' else 'Chưa' end
    ) as r
    from proposals p
    join proposal_lines l on l.proposal_id = p.id
    left join materials m on m.id = l.material_id
    left join doi_tuong dt on dt.id = p.doi_tuong_id
    where app_can_list_proposal(p, v_actor)
      and (p_from is null or p.ngay_de_xuat >= p_from)
      and (p_to is null or p.ngay_de_xuat <= p_to)
  ) x;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_get_printable_proposals(p_only_accepted boolean default true) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_rows jsonb;
begin
  v_actor := require_permission('print:purchasing');
  select coalesce(jsonb_agg(row_data order by (row_data->>'NgayDuyet') desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'MaDeXuat', p.ma_de_xuat,
      'LoaiDeXuat', p.loai_de_xuat,
      'NgayDeXuat', to_char(p.ngay_de_xuat, 'DD/MM/YYYY'),
      'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD'),
      'NoiDung', p.noi_dung,
      'GiaiTrinh', p.giai_trinh_ngoai_ke_hoach,
      'NguoiDeNghi', p.nguoi_de_nghi,
      'DieuKhoanTT', p.dieu_khoan_tt,
      'TenDoiTuong', p.ten_doi_tuong,
      'SoTk', dt.so_tk_ngan_hang,
      'ChiNhanh', dt.chi_nhanh_ngan_hang,
      'MST', dt.mst,
      'DaNghiemThu', exists (select 1 from debts d where d.proposal_id = p.id and d.sl_thuc_nhan is not null),
      'lines', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'MatHang', l.mat_hang,
          'SLDat', l.sl_dat,
          'DonGia', l.don_gia_chua_vat,
          'VATRate', l.vat_rate,
          'ThanhTienSauVAT', l.thanh_tien_sau_vat,
          'SLThucNhan', (select d.sl_thuc_nhan from debts d where d.proposal_id = p.id and d.mat_hang = l.mat_hang order by d.created_at limit 1),
          'GhiChu', l.ghi_chu
        ) order by l.ma_line), '[]'::jsonb)
        from proposal_lines l
        where l.proposal_id = p.id
      )
    ) as row_data
    from proposals p
    left join doi_tuong dt on dt.id = p.doi_tuong_id
    where p.trang_thai = 'Đã duyệt'
      and app_can_list_proposal(p, v_actor)
      and (not p_only_accepted or exists (select 1 from debts d where d.proposal_id = p.id and d.sl_thuc_nhan is not null))
    order by p.approved_at desc
    limit 300
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

revoke all on function app_department_id_from_name(text) from public, anon, authenticated;
revoke all on function app_ensure_department_id(text) from public, anon, authenticated;
revoke all on function app_profile_department_id(profiles) from public, anon, authenticated;
revoke all on function app_proposal_department_id(proposals) from public, anon, authenticated;
revoke all on function app_profile_department_name(profiles) from public, anon, authenticated;
revoke all on function app_same_department(proposals, profiles) from public, anon, authenticated;
revoke all on function app_can_view_proposal(proposals, profiles) from public, anon, authenticated;
revoke all on function app_can_list_proposal(proposals, profiles) from public, anon, authenticated;
revoke all on function app_can_oversight_proposal(proposals, profiles) from public, anon, authenticated;
revoke all on function app_actor_proposal_department(profiles, jsonb) from public, anon, authenticated;
revoke all on function app_proposal_detail_json(proposals) from public, anon, authenticated;

grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_update_proposal(text, jsonb) to authenticated;
grant execute on function rpc_get_proposal(text) to authenticated;
grant execute on function rpc_submit_proposal(text) to authenticated;
grant execute on function rpc_withdraw_proposal(text, text) to authenticated;
grant execute on function rpc_proposal_detail(text) to authenticated;
grant execute on function rpc_oversight(date, date) to authenticated;
grant execute on function rpc_oversight_proposal_detail(text) to authenticated;
grant execute on function rpc_cancel_proposal(text, text) to authenticated;
grant execute on function rpc_bounce_proposal(text, text) to authenticated;
grant execute on function rpc_approve_proposal(text, text) to authenticated;
grant execute on function rpc_reject_proposal(text, text) to authenticated;
grant execute on function rpc_get_approved_proposals(date) to authenticated;
grant execute on function rpc_get_recent(text, jsonb) to authenticated;
grant execute on function rpc_export_proposals(date, date) to authenticated;
grant execute on function rpc_get_printable_proposals(boolean) to authenticated;
