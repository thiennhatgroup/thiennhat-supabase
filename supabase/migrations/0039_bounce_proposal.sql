-- ============================================================================
-- 0039_bounce_proposal.sql
--  Kế toán / Trưởng bộ phận "TRẢ LẠI" (override) đề xuất mua hàng có vấn đề:
--   * Áp dụng cho phiếu ĐANG CHỜ DUYỆT hoặc ĐÃ DUYỆT (nhưng CHƯA phát sinh
--     thanh toán / chưa tất toán / chưa nằm trong đề xuất thanh toán nào).
--   * Nếu đã duyệt -> gỡ công nợ đã sinh, trả dòng về Nháp.
--   * Đặt phiếu về 'Nháp' + lưu lý do trả lại + báo người lập để giải trình và
--     tạo lại. (Khác với rpc_cancel_proposal: bản đó set 'Từ chối' ngõ cụt.)
-- ============================================================================

alter table proposals add column if not exists ly_do_tra_lai text;

create or replace function rpc_bounce_proposal(p_ma_de_xuat text, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_reason text := nullif(trim(coalesce(p_reason,'')),''); v_removed int := 0;
begin
  v_actor := require_permission('oversight:cancel');
  if v_reason is null then raise exception 'Cần nhập lý do trả lại để người lập giải trình.'; end if;
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai not in ('Chờ duyệt','Đã duyệt') then
    raise exception 'Chỉ trả lại được phiếu đang CHỜ DUYỆT hoặc ĐÃ DUYỆT (chưa thanh toán).';
  end if;
  if v_actor.role = 'TruongPhong' and (v_actor.bo_phan is null or v_p.bo_phan is distinct from v_actor.bo_phan) then
    raise exception 'Trưởng bộ phận chỉ được trả lại phiếu thuộc bộ phận mình.';
  end if;

  -- Nếu đã duyệt: chỉ cho gỡ khi công nợ chưa "dính" tiền.
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
    trang_thai = 'Nháp', nguoi_duyet = null, approved_at = null,
    ly_do_tra_lai = v_reason,
    ghi_chu = coalesce(ghi_chu,'') || ' | TRẢ LẠI (rà soát) bởi ' || coalesce(v_actor.name,'') || ': ' || v_reason
  where id = v_p.id;

  -- Báo người lập để giải trình + tạo lại (status -> Nháp không có nhánh notify tự động).
  if v_p.nguoi_tao is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (v_p.nguoi_tao, 'proposal_bounced', 'Đề xuất bị trả lại — cần giải trình',
            v_p.ma_de_xuat || ': ' || v_reason, 'proposal', v_p.ma_de_xuat);
  end if;

  perform write_audit(v_actor, 'BOUNCE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_p),
    jsonb_build_object('reason', v_reason, 'debtsRemoved', v_removed), 'OK', v_reason);
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'debtsRemoved', v_removed);
end; $$;

-- rpc_get_my_proposals: kèm lý do trả lại để nhân viên thấy ngay trên thẻ Nháp.
create or replace function rpc_get_my_proposals(p_limit int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_rows jsonb;
begin
  if v_uid is null then raise exception 'Chưa đăng nhập.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'MaDeXuat', ma_de_xuat, 'LoaiDeXuat', loai_de_xuat,
    'Ngay', to_char(ngay_de_xuat, 'YYYY-MM-DD'), 'TenDoiTuong', ten_doi_tuong,
    'TrangThai', trang_thai, 'GhiChu', ghi_chu, 'LyDoTraLai', ly_do_tra_lai,
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0)
  ) order by created_at desc), '[]'::jsonb) into v_rows
  from (select * from proposals where nguoi_tao = v_uid order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) p;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- Gửi duyệt lại: xóa cờ lý do trả lại.
create or replace function rpc_submit_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals;
begin
  v_actor := require_permission('proposal:submit');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_p.trang_thai <> 'Nháp' then raise exception 'Chỉ gửi duyệt được phiếu đang ở trạng thái Nháp.'; end if;
  if not v_p.trong_ke_hoach_tuan and nullif(trim(coalesce(v_p.giai_trinh_ngoai_ke_hoach,'')),'') is null then
    raise exception 'Khoản ngoài kế hoạch chi tuần — cần giải trình trước khi gửi duyệt.';
  end if;
  update proposals set trang_thai = 'Chờ duyệt', ly_do_tra_lai = null where id = v_p.id;
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

grant execute on function rpc_bounce_proposal(text, text) to authenticated;
grant execute on function rpc_get_my_proposals(int) to authenticated;
grant execute on function rpc_submit_proposal(text) to authenticated;
