-- ============================================================================
-- 0042_oversight_detail.sql
--  * rpc_oversight_proposal_detail: kế toán / trưởng bộ phận xem CHI TIẾT đầy đủ
--    một đề xuất (mọi trường + đính kèm + mốc thời gian tạo/duyệt + người duyệt
--    + bộ phận + dòng vật tư), y như lãnh đạo thấy khi duyệt. TBP chỉ xem phiếu
--    thuộc bộ phận mình.
--  * rpc_bounce_proposal: thông báo trả lại KÈM TÊN người trả lại (để NV mua
--    hàng biết ai trả lại PO của mình).
-- ============================================================================

create or replace function rpc_oversight_proposal_detail(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor profiles; v_p proposals; v_j jsonb;
begin
  v_actor := require_permission('oversight:read');
  select * into v_p from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_p is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_actor.role = 'TruongPhong' and (v_actor.bo_phan is null or v_p.bo_phan is distinct from v_actor.bo_phan) then
    raise exception 'Trưởng bộ phận chỉ xem được phiếu thuộc bộ phận mình.';
  end if;

  select jsonb_build_object(
    'MaDeXuat', v_p.ma_de_xuat,
    'LoaiDeXuat', v_p.loai_de_xuat,
    'TrangThai', v_p.trang_thai,
    'BoPhan', v_p.bo_phan,
    'NguoiDeNghi', v_p.nguoi_de_nghi,
    'NguoiTao', (select name from profiles where id = v_p.nguoi_tao),
    'TenDoiTuong', v_p.ten_doi_tuong,
    'DieuKhoanTT', v_p.dieu_khoan_tt,
    'HanThanhToan', to_char(v_p.han_thanh_toan, 'YYYY-MM-DD'),
    'TonKho', v_p.ton_kho,
    'TruongBpDuyet', v_p.truong_bp_duyet,
    'Prepay', v_p.prepay,
    'TrongKeHoachTuan', v_p.trong_ke_hoach_tuan,
    'GiaiTrinhNgoaiKeHoach', v_p.giai_trinh_ngoai_ke_hoach,
    'NoiDung', v_p.noi_dung,
    'GhiChu', v_p.ghi_chu,
    'LyDoTraLai', v_p.ly_do_tra_lai,
    'Attachments', coalesce(v_p.attachments, '[]'::jsonb),
    'ThoiGianTao', to_char(v_p.created_at, 'YYYY-MM-DD HH24:MI'),
    'ThoiGianDuyet', to_char(v_p.approved_at, 'YYYY-MM-DD HH24:MI'),
    'NguoiDuyet', (select name from profiles where id = v_p.nguoi_duyet),
    'DaNghiemThu', exists(select 1 from debts d where d.proposal_id = v_p.id and d.sl_thuc_nhan is not null),
    'DaPhatSinhTT', exists(select 1 from debts d where d.proposal_id = v_p.id and d.da_thanh_toan > 0),
    'TongTien', coalesce((select sum(thanh_tien_sau_vat) from proposal_lines where proposal_id = v_p.id), 0),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
        'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu
      ) order by l.ma_line), '[]'::jsonb) from proposal_lines l where l.proposal_id = v_p.id)
  ) into v_j;
  return jsonb_build_object('ok', true, 'proposal', v_j);
end; $$;

-- Trả lại: thông báo kèm TÊN người trả lại.
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

  if v_p.nguoi_tao is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    values (v_p.nguoi_tao, 'proposal_bounced',
            'Đề xuất bị trả lại — cần giải trình',
            v_p.ma_de_xuat || ' bị ' || coalesce(v_actor.name,'(rà soát)') || ' (' || v_actor.role || ') trả lại: ' || v_reason,
            'proposal', v_p.ma_de_xuat);
  end if;

  perform write_audit(v_actor, 'BOUNCE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_p),
    jsonb_build_object('reason', v_reason, 'debtsRemoved', v_removed), 'OK', v_reason);
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat, 'debtsRemoved', v_removed);
end; $$;

grant execute on function rpc_oversight_proposal_detail(text) to authenticated;
grant execute on function rpc_bounce_proposal(text, text) to authenticated;
