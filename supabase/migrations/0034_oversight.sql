-- ============================================================================
-- 0034_oversight.sql — Màn "Theo dõi & rà soát" cho Kế toán / Trưởng bộ phận
--   * profiles.bo_phan: gắn bộ phận cho user (để TBP chỉ thấy phiếu bộ phận mình)
--   * oversight:read / oversight:cancel cho KeToanCongNo + TruongPhong
--   * rpc_oversight(from,to): tất cả ĐX mua hàng + ĐX thanh toán mọi trạng thái;
--       TruongPhong chỉ thấy ĐX mua hàng thuộc bộ phận mình, không thấy ĐX TT.
--   * rpc_cancel_proposal / rpc_cancel_payment_request: hủy phiếu ĐANG chờ duyệt
--       trước khi sếp xem (trigger sẵn có sẽ báo cho người lập).
-- ============================================================================

alter table profiles add column if not exists bo_phan text;

insert into role_permissions (role, permission) values
  ('KeToanCongNo', 'oversight:read'), ('KeToanCongNo', 'oversight:cancel'),
  ('TruongPhong',  'oversight:read'), ('TruongPhong',  'oversight:cancel'),
  ('TruongPhong',  'recent:read')
on conflict (role, permission) do nothing;

create or replace function rpc_oversight(p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_props jsonb; v_pays jsonb; v_tbp boolean;
begin
  v_actor := require_permission('oversight:read');
  v_tbp := (v_actor.role = 'TruongPhong');

  select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_props
  from (
    select jsonb_build_object(
      'MaDeXuat', p.ma_de_xuat, 'Loai', case when p.loai_de_xuat='TamUng' then 'Tạm ứng' else 'Mua hàng' end,
      'Ngay', to_char(p.ngay_de_xuat,'YYYY-MM-DD'), 'NguoiDeNghi', p.nguoi_de_nghi, 'BoPhan', p.bo_phan,
      'TenDoiTuong', p.ten_doi_tuong, 'TrangThai', p.trang_thai, 'HanThanhToan', to_char(p.han_thanh_toan,'YYYY-MM-DD'),
      'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id=p.id),0),
      'DaNghiemThu', exists(select 1 from debts d where d.proposal_id=p.id and d.sl_thuc_nhan is not null),
      'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id=p.id and d.da_thanh_toan>0)
    ) as x
    from proposals p
    where (p_from is null or p.ngay_de_xuat >= p_from) and (p_to is null or p.ngay_de_xuat <= p_to)
      and (not v_tbp or (v_actor.bo_phan is not null and p.bo_phan = v_actor.bo_phan))
    order by p.ngay_de_xuat desc limit 500
  ) t;

  if v_tbp then
    v_pays := '[]'::jsonb;   -- Trưởng bộ phận không xem đề xuất thanh toán (thuộc kế toán)
  else
    select coalesce(jsonb_agg(x order by (x->>'Ngay') desc), '[]'::jsonb) into v_pays
    from (
      select jsonb_build_object(
        'MaDeXuatTT', pr.ma_de_xuat_tt, 'Ngay', to_char(pr.ngay,'YYYY-MM-DD'), 'TrangThai', pr.trang_thai,
        'NguoiLap', (select name from profiles where id=pr.nguoi_lap),
        'TongTien', coalesce((select sum(so_tien) from payment_request_lines where request_id=pr.id),0)
      ) as x
      from payment_requests pr
      where (p_from is null or pr.ngay >= p_from) and (p_to is null or pr.ngay <= p_to)
      order by pr.ngay desc limit 500
    ) t;
  end if;

  return jsonb_build_object('ok', true, 'role', v_actor.role, 'proposals', v_props, 'paymentRequests', v_pays);
end; $$;

create or replace function rpc_cancel_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals;
begin
  v_actor := require_permission('oversight:cancel');
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cần nhập lý do hủy để báo người lập.'; end if;
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai <> 'Chờ duyệt' then raise exception 'Chỉ hủy được phiếu đang CHỜ DUYỆT (trước khi sếp duyệt).'; end if;
  if v_actor.role = 'TruongPhong' and (v_actor.bo_phan is null or v_p.bo_phan is distinct from v_actor.bo_phan) then
    raise exception 'Trưởng bộ phận chỉ được hủy phiếu thuộc bộ phận mình.';
  end if;
  update proposals set trang_thai = 'Từ chối', ghi_chu = coalesce(ghi_chu,'') || ' | HỦY (rà soát) bởi ' || coalesce(v_actor.name,'') || ': ' || trim(p_reason)
  where id = v_p.id;
  perform write_audit(v_actor, 'CANCEL_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_p), jsonb_build_object('reason', p_reason), 'OK', trim(p_reason));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end; $$;

create or replace function rpc_cancel_payment_request(p_ma text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_pr payment_requests;
begin
  v_actor := require_permission('oversight:cancel');
  if v_actor.role = 'TruongPhong' then raise exception 'Đề xuất thanh toán do kế toán/lãnh đạo xử lý.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cần nhập lý do hủy.'; end if;
  select * into v_pr from payment_requests where ma_de_xuat_tt = p_ma;
  if v_pr is null then raise exception 'Không tìm thấy đề xuất thanh toán %.', p_ma; end if;
  if v_pr.trang_thai <> 'Chờ duyệt' then raise exception 'Chỉ hủy được đề xuất đang CHỜ DUYỆT.'; end if;
  update payment_requests set trang_thai = 'Từ chối', ly_do_tu_choi = 'HỦY (rà soát): ' || trim(p_reason) where id = v_pr.id;
  perform write_audit(v_actor, 'CANCEL_PAYMENT_REQUEST', 'payment_requests', p_ma, to_jsonb(v_pr), jsonb_build_object('reason', p_reason), 'OK', trim(p_reason));
  return jsonb_build_object('ok', true, 'maDeXuatTT', p_ma);
end; $$;

-- Cho phép gán bộ phận cho user khi sửa hồ sơ (bỏ bản 4 tham số cũ để tránh xung đột)
drop function if exists rpc_admin_update_user(uuid, text, text, text);
create or replace function rpc_admin_update_user(p_id uuid, p_role text default null, p_status text default null, p_name text default null, p_bo_phan text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_before jsonb; v_row profiles;
begin
  v_actor := require_permission('user:manage');
  select to_jsonb(p) into v_before from profiles p where id = p_id;
  if v_before is null then raise exception 'Không tìm thấy tài khoản.'; end if;
  if p_role is not null and p_role not in ('NhanVienMuaHang','TruongPhong','KeToanCongNo','LanhDao','ChuTich','TongGiamDoc','Admin') then
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

grant execute on function rpc_oversight(date, date) to authenticated;
grant execute on function rpc_cancel_proposal(text, text) to authenticated;
grant execute on function rpc_cancel_payment_request(text, text) to authenticated;
grant execute on function rpc_admin_update_user(uuid, text, text, text, text) to authenticated;
