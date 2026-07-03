-- ============================================================================
-- 0057_cashier_and_dashboard.sql  (Batch Thủ quỹ & Dashboard)
--  * Thêm vai trò THỦ QUỸ. Chỉ thủ quỹ được "đi tiền" (payment:execute) —
--    gỡ quyền này khỏi kế toán (KTTH chỉ tổng hợp + trình).
--  * Thủ quỹ xác nhận đã chuyển: hệ thống TỰ TRỪ CÔNG NỢ + lưu ẢNH CHUYỂN KHOẢN
--    + BÁO NVMH (người tạo đề xuất mua hàng của khoản đó).
--  * Dashboard lãnh đạo: tổng ĐXMH hôm nay theo bộ phận, tổng ĐXTT hôm nay,
--    tổng chi theo kỳ + theo bộ phận, chi tiết khoản đã chi, top NCC.
-- ============================================================================

-- ---- Cho phép vai trò ThuQuy trong ràng buộc + whitelist admin -------------
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin'));

-- rpc_admin_create_user: mở whitelist đủ vai trò hiện hành + ThuQuy.
create or replace function rpc_admin_create_user(p_email text, p_name text, p_role text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor profiles; v_uid uuid := gen_random_uuid();
  v_email text := lower(trim(coalesce(p_email,''))); v_pin text := trim(coalesce(p_pin,'')); v_pw text;
begin
  v_actor := require_permission('user:manage');
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'Email không hợp lệ.'; end if;
  if p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if length(v_pin) < 4 then raise exception 'Mã PIN cần ít nhất 4 ký tự.'; end if;
  if exists (select 1 from auth.users where email = v_email) then raise exception 'Email % đã tồn tại.', v_email; end if;
  v_pw := 'tn-pin::' || v_pin;
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
    crypt(v_pw, gen_salt('bf')), now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', coalesce(nullif(trim(p_name),''), v_email)),
    false, '', '', '', ''
  );
  insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid::text, v_uid, jsonb_build_object('sub', v_uid::text, 'email', v_email), 'email', now(), now(), now());
  insert into profiles (id, email, name, role, status)
  values (v_uid, v_email, coalesce(nullif(trim(p_name),''), v_email), p_role, 'Hoạt động');
  perform write_audit(v_actor, 'CREATE_USER', 'profiles', v_uid::text, null, jsonb_build_object('email', v_email, 'role', p_role), 'OK', '');
  return jsonb_build_object('ok', true, 'id', v_uid, 'email', v_email);
end; $$;
grant execute on function rpc_admin_create_user(text, text, text, text) to authenticated;

-- rpc_admin_update_user: thêm ThuQuy vào whitelist (giữ chữ ký 5 tham số).
create or replace function rpc_admin_update_user(p_id uuid, p_role text default null, p_status text default null, p_name text default null, p_bo_phan text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_before jsonb; v_row profiles;
begin
  v_actor := require_permission('user:manage');
  select to_jsonb(p) into v_before from profiles p where id = p_id;
  if v_before is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  if p_role is not null and p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','ThuQuy','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.'; end if;
  if p_status is not null and p_status not in ('Hoạt động','Ngừng') then raise exception 'Trạng thái không hợp lệ.'; end if;
  update profiles set
    role = coalesce(nullif(trim(coalesce(p_role,'')),''), role),
    status = coalesce(nullif(trim(coalesce(p_status,'')),''), status),
    name = coalesce(nullif(trim(coalesce(p_name,'')),''), name),
    bo_phan = coalesce(p_bo_phan, bo_phan)
  where id = p_id returning * into v_row;
  perform write_audit(v_actor, 'UPDATE_USER', 'profiles', p_id::text, v_before, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'id', p_id);
end; $$;
grant execute on function rpc_admin_update_user(uuid, text, text, text, text) to authenticated;

-- ---- Vai trò Thủ quỹ + quyền -----------------------------------------------
insert into role_permissions (role, permission) values
  ('ThuQuy', 'payment:execute'),
  ('ThuQuy', 'payment:read')
on conflict (role, permission) do nothing;
-- Kế toán không còn "đi tiền" (thủ quỹ phụ trách).
delete from role_permissions where role = 'KeToanCongNo' and permission = 'payment:execute';

-- ---- Ảnh uỷ nhiệm chi / chuyển khoản lưu trên payment ----------------------
alter table payments add column if not exists proof_files jsonb not null default '[]'::jsonb;

-- ---- Thủ quỹ xác nhận chi: trừ công nợ + lưu ảnh + báo NVMH -----------------
-- (Đổi chữ ký: thêm p_proof jsonb -> phải drop bản cũ trước.)
drop function if exists rpc_execute_payment_request(text);
create or replace function rpc_execute_payment_request(p_ma text, p_proof jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles; v_pr payment_requests; v_line payment_request_lines;
  v_ma_tt text; v_pay_id uuid; v_dt doi_tuong; v_ma_cn text; v_n int := 0;
  v_creator uuid; v_ma_dx text;
begin
  v_actor := require_permission('payment:execute');
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Đã duyệt' then
    raise exception 'Chỉ xác nhận chuyển tiền sau khi đề xuất % đã được lãnh đạo DUYỆT.', p_ma;
  end if;

  for v_line in select * from payment_request_lines where request_id = v_pr.id loop
    v_ma_cn := null; v_creator := null; v_ma_dx := null;
    if v_line.debt_id is not null then
      select ma_cn into v_ma_cn from debts where id = v_line.debt_id;
      select p.nguoi_tao, p.ma_de_xuat into v_creator, v_ma_dx
        from debts d left join proposals p on p.id = d.proposal_id where d.id = v_line.debt_id;
    end if;
    if v_line.doi_tuong_id is not null then
      select * into v_dt from doi_tuong where id = v_line.doi_tuong_id;
    else
      v_dt := ensure_doi_tuong(null, v_line.ncc, 'NCC', null, null, null, null);
    end if;

    v_ma_tt := next_code('TT');
    insert into payments (ma_thanh_toan, ngay_thanh_toan, doi_tuong_id, ten_doi_tuong, so_tien, phan_bo_mode, ma_cn, chung_tu, ghi_chu, nguoi_nhap, trang_thai, proof_files)
    values (v_ma_tt, current_date, v_dt.id, v_dt.ten_doi_tuong, v_line.so_tien,
            case when v_line.debt_id is not null then 'MA_CN' else 'FIFO' end,
            v_ma_cn, null, format('Chi theo ĐXTT %s | %s', p_ma, coalesce(v_line.noi_dung,'')), v_actor.id, 'Đã ghi nhận',
            coalesce(p_proof, '[]'::jsonb))
    returning id into v_pay_id;

    if v_line.debt_id is not null then
      insert into payment_allocations (payment_id, debt_id, ma_cn, so_tien_phan_bo)
      values (v_pay_id, v_line.debt_id, v_ma_cn, v_line.so_tien);
      update debts set da_thanh_toan = da_thanh_toan + v_line.so_tien, ngay_tt_cuoi = current_date
      where id = v_line.debt_id;
      -- Báo NVMH đã tạo đề xuất mua hàng của khoản này.
      if v_creator is not null then
        insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
        values (v_creator, 'payment_done', 'Khoản của bạn đã được chuyển tiền',
                coalesce(v_ma_dx,'') || ' · ' || coalesce(v_ma_cn,'') || ' · ' || to_char(v_line.so_tien,'FM999,999,999') || 'đ đã chuyển (thủ quỹ: ' || coalesce(v_actor.name,'') || ')',
                'proposal', coalesce(v_ma_dx, v_ma_cn));
      end if;
    end if;
    v_n := v_n + 1;
  end loop;

  update payment_requests set trang_thai = 'Đã chi', executed_at = now() where id = v_pr.id;
  perform write_audit(v_actor, 'CASHIER_EXECUTE', 'payment_requests', p_ma, to_jsonb(v_pr),
    jsonb_build_object('payments', v_n, 'proof', jsonb_array_length(coalesce(p_proof,'[]'::jsonb))), 'OK', 'Thủ quỹ xác nhận đã chuyển, trừ công nợ.');
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma, 'payments', v_n);
end; $$;
grant execute on function rpc_execute_payment_request(text, jsonb) to authenticated;

-- ---- Hàng đợi của thủ quỹ: ĐXTT đã lãnh đạo duyệt, đủ thông tin chuyển ------
create or replace function rpc_get_cashier_queue() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform require_permission('payment:execute');
  select coalesce(jsonb_agg(x order by (x->>'ngay') asc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'maDeXuatTT', pr.ma_de_xuat_tt, 'ngay', to_char(pr.ngay,'YYYY-MM-DD'),
      'nguoiLap', (select name from profiles where id = pr.nguoi_lap),
      'tong', coalesce((select sum(so_tien) from payment_request_lines where request_id = pr.id), 0),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object(
          'ncc', l.ncc, 'soTien', l.so_tien, 'noiDung', l.noi_dung, 'hinhThucTT', l.hinh_thuc_tt,
          'maCN', (select ma_cn from debts where id = l.debt_id),
          'soTk', dt.so_tk_ngan_hang, 'chiNhanh', dt.chi_nhanh_ngan_hang, 'mst', dt.mst,
          'chungTu', coalesce((select nghiem_thu_files from debts where id = l.debt_id), '[]'::jsonb)
        ) order by l.created_at), '[]'::jsonb)
        from payment_request_lines l left join doi_tuong dt on dt.id = l.doi_tuong_id
        where l.request_id = pr.id)
    ) as x
    from payment_requests pr
    where pr.trang_thai = 'Đã duyệt'
  ) t;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end; $$;
grant execute on function rpc_get_cashier_queue() to authenticated;

-- ---- Dashboard lãnh đạo -----------------------------------------------------
create or replace function rpc_leader_dashboard(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := coalesce(p_from, current_date - 30);
  v_to date := coalesce(p_to, current_date);
  v_dxmh jsonb; v_dxmh_bp jsonb; v_dxtt jsonb; v_chi jsonb; v_chi_bp jsonb; v_chi_detail jsonb; v_topncc jsonb;
begin
  perform require_permission('dashboard:read');

  -- ĐXMH hôm nay (đã trình) + theo bộ phận
  select jsonb_build_object(
    'count', count(*),
    'total', coalesce(sum((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id)), 0)
  ) into v_dxmh
  from proposals p where p.created_at::date = current_date and p.trang_thai <> 'Nháp';

  select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'total', t) order by t desc), '[]'::jsonb) into v_dxmh_bp
  from (
    select coalesce(p.bo_phan,'(không rõ)') as bp,
           coalesce(sum((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id)),0) as t
    from proposals p where p.created_at::date = current_date and p.trang_thai <> 'Nháp'
    group by 1
  ) s;

  -- ĐXTT hôm nay
  select jsonb_build_object(
    'count', count(distinct pr.id),
    'total', coalesce(sum(l.so_tien), 0)
  ) into v_dxtt
  from payment_requests pr join payment_request_lines l on l.request_id = pr.id
  where pr.ngay = current_date and pr.trang_thai <> 'Nháp';

  -- Chi trong kỳ (đã ghi nhận bởi thủ quỹ) — tổng + theo bộ phận
  select jsonb_build_object('total', coalesce(sum(pm.so_tien),0), 'count', count(*)) into v_chi
  from payments pm where pm.ngay_thanh_toan between v_from and v_to;

  select coalesce(jsonb_agg(jsonb_build_object('boPhan', bp, 'total', t) order by t desc), '[]'::jsonb) into v_chi_bp
  from (
    select coalesce(pr.bo_phan, '(ngoài phần mềm)') as bp, sum(pm.so_tien) as t
    from payments pm
    left join debts d on d.ma_cn = pm.ma_cn
    left join proposals pr on pr.id = d.proposal_id
    where pm.ngay_thanh_toan between v_from and v_to
    group by 1
  ) s;

  -- Chi tiết các khoản đã chi trong kỳ
  select coalesce(jsonb_agg(jsonb_build_object(
    'maThanhToan', pm.ma_thanh_toan, 'ngay', to_char(pm.ngay_thanh_toan,'YYYY-MM-DD'),
    'ncc', pm.ten_doi_tuong, 'soTien', pm.so_tien, 'maCN', pm.ma_cn,
    'boPhan', coalesce(pr.bo_phan,'(ngoài phần mềm)'), 'ghiChu', pm.ghi_chu,
    'proof', coalesce(pm.proof_files,'[]'::jsonb)
  ) order by pm.ngay_thanh_toan desc, pm.created_at desc), '[]'::jsonb) into v_chi_detail
  from payments pm
  left join debts d on d.ma_cn = pm.ma_cn
  left join proposals pr on pr.id = d.proposal_id
  where pm.ngay_thanh_toan between v_from and v_to;

  -- Top NCC chi nhiều nhất trong kỳ (kèm bộ phận + lũy kế)
  select coalesce(jsonb_agg(jsonb_build_object('ncc', ncc, 'boPhan', bp, 'total', t) order by t desc), '[]'::jsonb) into v_topncc
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

  return jsonb_build_object('ok', true,
    'from', to_char(v_from,'YYYY-MM-DD'), 'to', to_char(v_to,'YYYY-MM-DD'),
    'dxmhToday', v_dxmh, 'dxmhByBoPhan', v_dxmh_bp, 'dxttToday', v_dxtt,
    'chi', v_chi, 'chiByBoPhan', v_chi_bp, 'chiDetail', v_chi_detail, 'topNcc', v_topncc);
end; $$;
grant execute on function rpc_leader_dashboard(date, date) to authenticated;
