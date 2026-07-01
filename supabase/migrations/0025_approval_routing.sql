-- ============================================================================
-- 0025_approval_routing.sql
-- Phân luồng duyệt theo mức tiền cho ĐỀ XUẤT MUA HÀNG:
--   * tổng phiếu >= 10.000.000đ  -> Chủ tịch (ChuTich) duyệt
--   * tổng phiếu <  10.000.000đ  -> Tổng giám đốc (TongGiamDoc) duyệt
-- Đề xuất THANH TOÁN: Chủ tịch duyệt cuối (payment:approve chỉ cấp cho ChuTich).
-- Ngưỡng lấy từ app_config('approval_threshold') để chỉnh được sau này.
-- ============================================================================

-- 1) Thêm 2 vai trò lãnh đạo
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','LanhDao','ChuTich','TongGiamDoc','Admin'));

-- 2) Ngưỡng duyệt
insert into app_config (key, value) values ('approval_threshold', '10000000')
on conflict (key) do nothing;

-- 3) Quyền
insert into role_permissions (role, permission) values
  ('ChuTich', 'proposal:approve'), ('ChuTich', 'proposal:reject'),
  ('ChuTich', 'payment:approve'),  ('ChuTich', 'quote:read'),
  ('ChuTich', 'recent:read'),      ('ChuTich', 'dashboard:read'),
  ('TongGiamDoc', 'proposal:approve'), ('TongGiamDoc', 'proposal:reject'),
  ('TongGiamDoc', 'quote:read'),   ('TongGiamDoc', 'recent:read'),
  ('TongGiamDoc', 'dashboard:read')
on conflict (role, permission) do nothing;

-- 4) Duyệt đề xuất: enforce đúng cấp theo mức tiền
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
  if v_proposal is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_proposal.trang_thai not in ('Chờ duyệt', 'Nháp') then
    raise exception 'Đề xuất % không ở trạng thái có thể duyệt.', p_ma_de_xuat;
  end if;

  select coalesce(sum(thanh_tien_sau_vat), 0) into v_total from proposal_lines where proposal_id = v_proposal.id;
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';

  -- Routing theo cấp (Admin bỏ qua)
  if v_actor.role <> 'Admin' then
    if v_total >= v_threshold and v_actor.role <> 'ChuTich' then
      raise exception 'Khoản % đ (≥ %) thuộc thẩm quyền CHỦ TỊCH.', to_char(v_total, 'FM999,999,999'), to_char(v_threshold, 'FM999,999,999');
    elsif v_total < v_threshold and v_actor.role <> 'TongGiamDoc' then
      raise exception 'Khoản % đ (< %) thuộc thẩm quyền TỔNG GIÁM ĐỐC.', to_char(v_total, 'FM999,999,999'), to_char(v_threshold, 'FM999,999,999');
    end if;
  end if;

  for v_line in select * from proposal_lines where proposal_id = v_proposal.id
  loop
    insert into debts (
      ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no,
      proposal_id, ma_lo_hang, mat_hang, sl_dat, don_gia, vat_rate,
      dieu_khoan_tt, ghi_chu, nguon_tao
    ) values (
      next_code('CN'), v_proposal.ngay_de_xuat, v_now, v_proposal.doi_tuong_id, v_proposal.ten_doi_tuong,
      case when v_proposal.loai_de_xuat = 'TamUng' then 'TamUng' else 'AP' end,
      v_proposal.id, p_ma_de_xuat || '-' || lpad((v_row_count + 1)::text, 2, '0'), v_line.mat_hang, v_line.sl_dat,
      v_line.don_gia_chua_vat, v_line.vat_rate,
      v_proposal.dieu_khoan_tt, format('WebApp | Nội dung: %s | Ghi chú: %s', coalesce(v_proposal.noi_dung, ''), coalesce(v_line.ghi_chu, '')),
      'WebApp'
    ) returning id into v_new_debt_id;
    v_row_count := v_row_count + 1;
    update proposal_lines set trang_thai = 'Đã duyệt', debt_id = v_new_debt_id where id = v_line.id;
  end loop;

  update proposals set trang_thai = 'Đã duyệt', nguoi_duyet = v_actor.id, approved_at = now(),
    ghi_chu = case when nullif(trim(coalesce(p_note,'')),'') is not null
                   then coalesce(ghi_chu,'') || ' | Duyệt: ' || trim(p_note) else ghi_chu end
  where id = v_proposal.id;

  perform write_audit(v_actor, 'APPROVE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal),
    jsonb_build_object('rows', v_row_count, 'total', v_total, 'note', p_note), 'OK',
    coalesce(nullif(trim(p_note),''),'Đã duyệt và chuyển sang công nợ.'));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'congNoRows', v_row_count);
end;
$$;

-- 5) Danh sách chờ duyệt lọc theo cấp của người duyệt
create or replace function rpc_get_pending_proposals(p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_threshold numeric; v_rows jsonb;
begin
  v_actor := require_permission('proposal:approve');
  select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';

  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_rows
  from (
    select p.created_at, jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat, 'LoaiDeXuat', p.loai_de_xuat,
        'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'TenDoiTuong', p.ten_doi_tuong, 'NoiDung', p.noi_dung, 'DieuKhoanTT', p.dieu_khoan_tt,
        'NguoiDeNghi', p.nguoi_de_nghi, 'TrangThai', p.trang_thai, 'GhiChu', p.ghi_chu,
        'TrongKeHoachTuan', p.trong_ke_hoach_tuan, 'GiaiTrinhNgoaiKeHoach', p.giai_trinh_ngoai_ke_hoach,
        'TongTien', v_tong,
        'lines', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'MaLine', l.ma_line, 'MatHang', l.mat_hang, 'SLDat', l.sl_dat,
            'DonGiaChuaVAT', l.don_gia_chua_vat, 'VATRate', l.vat_rate,
            'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu
          ) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id
        )
      ) as row_data
    from proposals p
    cross join lateral (select coalesce(sum(thanh_tien_sau_vat),0) as v_tong from proposal_lines where proposal_id = p.id) t
    where p.trang_thai = 'Chờ duyệt'
      and (
        v_actor.role = 'Admin'
        or (v_actor.role = 'ChuTich' and t.v_tong >= v_threshold)
        or (v_actor.role = 'TongGiamDoc' and t.v_tong < v_threshold)
        or v_actor.role not in ('ChuTich','TongGiamDoc','Admin')
      )
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- 6) Thông báo: đề xuất mua hàng -> báo cả 2 cấp (danh sách sẽ tự lọc đúng cấp);
--    đề xuất thanh toán -> Chủ tịch.
create or replace function trg_proposals_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'INSERT' and NEW.trang_thai = 'Chờ duyệt' then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    select id, 'proposal_pending', 'Đề xuất mua hàng chờ duyệt',
           NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong,''), 'approve', NEW.ma_de_xuat
    from profiles where role in ('ChuTich','TongGiamDoc') and status = 'Hoạt động';
  elsif TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    if NEW.trang_thai = 'Chờ duyệt' then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'proposal_pending', 'Đề xuất gửi lại chờ duyệt',
             NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong,''), 'approve', NEW.ma_de_xuat
      from profiles where role in ('ChuTich','TongGiamDoc') and status = 'Hoạt động';
    elsif NEW.trang_thai = 'Đã duyệt' and NEW.nguoi_tao is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_tao, 'proposal_approved', 'Đề xuất đã được duyệt',
              NEW.ma_de_xuat || ' đã duyệt — sẵn sàng nghiệm thu.', 'receipt', NEW.ma_de_xuat);
    elsif NEW.trang_thai = 'Từ chối' and NEW.nguoi_tao is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_tao, 'proposal_rejected', 'Đề xuất bị từ chối / hủy duyệt',
              NEW.ma_de_xuat || ': ' || coalesce(NEW.ghi_chu,''), 'proposal', NEW.ma_de_xuat);
    end if;
  end if;
  return NEW;
end;
$$;

create or replace function trg_payreq_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'INSERT' and NEW.trang_thai = 'Chờ duyệt' then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    select id, 'payreq_pending', 'Đề xuất thanh toán chờ duyệt', NEW.ma_de_xuat_tt, 'payapprove', NEW.ma_de_xuat_tt
    from profiles where role = 'ChuTich' and status = 'Hoạt động';
  elsif TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    if NEW.trang_thai = 'Chờ duyệt' then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'payreq_pending', 'Đề xuất thanh toán chờ duyệt', NEW.ma_de_xuat_tt, 'payapprove', NEW.ma_de_xuat_tt
      from profiles where role = 'ChuTich' and status = 'Hoạt động';
    elsif NEW.trang_thai = 'Đã duyệt' and NEW.nguoi_lap is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_lap, 'payreq_approved', 'Đề xuất thanh toán đã duyệt',
              NEW.ma_de_xuat_tt || ' đã duyệt — có thể đi tiền.', 'payreq', NEW.ma_de_xuat_tt);
    elsif NEW.trang_thai = 'Từ chối' and NEW.nguoi_lap is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_lap, 'payreq_rejected', 'Đề xuất thanh toán bị từ chối',
              NEW.ma_de_xuat_tt || ': ' || coalesce(NEW.ly_do_tu_choi,''), 'payreq', NEW.ma_de_xuat_tt);
    end if;
  end if;
  return NEW;
end;
$$;

-- 7) Cho phép gán 2 vai trò mới khi sửa hồ sơ trong app
create or replace function rpc_admin_update_user(p_id uuid, p_role text default null, p_status text default null, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_before jsonb; v_row profiles;
begin
  v_actor := require_permission('user:manage');
  select to_jsonb(p) into v_before from profiles p where id = p_id;
  if v_before is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  if p_role is not null and p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','LanhDao','ChuTich','TongGiamDoc','Admin') then
    raise exception 'Vai trò không hợp lệ.';
  end if;
  if p_status is not null and p_status not in ('Hoạt động','Ngừng') then raise exception 'Trạng thái không hợp lệ.'; end if;
  update profiles set
    role = coalesce(nullif(trim(coalesce(p_role,'')),''), role),
    status = coalesce(nullif(trim(coalesce(p_status,'')),''), status),
    name = coalesce(nullif(trim(coalesce(p_name,'')),''), name)
  where id = p_id returning * into v_row;
  perform write_audit(v_actor, 'UPDATE_USER', 'profiles', p_id::text, v_before, to_jsonb(v_row), 'OK', '');
  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;
