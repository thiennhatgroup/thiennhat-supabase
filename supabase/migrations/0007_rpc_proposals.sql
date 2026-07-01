-- ============================================================================
-- 0007_rpc_proposals.sql
-- rpc_create_proposal()    mirrors apiCreateProposal()
-- rpc_get_pending_proposals() mirrors apiGetPendingProposals() / getProposalBundle_()
-- rpc_approve_proposal()   mirrors apiApproveProposal()
-- rpc_reject_proposal()    mirrors apiRejectProposal()
--
-- Payload shape for rpc_create_proposal (same field names the frontend
-- already sends, just as one jsonb argument instead of separate params):
-- {
--   "status": "Nháp" | "Chờ duyệt",
--   "ngayDeXuat": "2026-07-01",
--   "nguoiDeNghi": "Nguyễn Văn A",
--   "doiTuong": { "ma": "", "ten": "Công ty ABC", "dieuKhoanTT": "" },
--   "noiDung": "...",
--   "dieuKhoanTT": "...",
--   "ghiChu": "...",
--   "lines": [ { "matHang": "Đá 1x2", "slDat": 500, "donGia": 220000, "vat": "8%", "ghiChu": "" }, ... ]
-- }
-- ============================================================================

create or replace function rpc_create_proposal(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text := case when coalesce(p_payload->>'status', 'Nháp') = 'Chờ duyệt' then 'Chờ duyệt' else 'Nháp' end;
  v_actor profiles;
  v_doi_tuong doi_tuong;
  v_ma_de_xuat text;
  v_proposal_id uuid;
  v_line jsonb;
  v_qty numeric;
  v_price numeric;
  v_vat numeric;
  v_line_count int := 0;
  v_header jsonb;
begin
  v_actor := require_permission(case when v_status = 'Chờ duyệt' then 'proposal:submit' else 'proposal:create' end);

  if p_payload->'lines' is null or jsonb_array_length(p_payload->'lines') = 0 then
    raise exception 'Đề xuất cần ít nhất một dòng vật tư có mặt hàng, số lượng và đơn giá.';
  end if;

  v_doi_tuong := ensure_doi_tuong(
    p_payload->'doiTuong'->>'ma',
    p_payload->'doiTuong'->>'ten',
    coalesce(p_payload->'doiTuong'->>'loai', 'NCC'),
    p_payload->'doiTuong'->>'mst',
    p_payload->'doiTuong'->>'diaChi',
    p_payload->'doiTuong'->>'contact',
    coalesce(p_payload->'doiTuong'->>'dieuKhoanTT', p_payload->>'dieuKhoanTT')
  );

  v_ma_de_xuat := next_code('DX');

  insert into proposals (ma_de_xuat, ngay_de_xuat, nguoi_de_nghi, doi_tuong_id, ten_doi_tuong, noi_dung, dieu_khoan_tt, trang_thai, nguoi_tao, ghi_chu)
  values (
    v_ma_de_xuat,
    coalesce((p_payload->>'ngayDeXuat')::date, current_date),
    coalesce(p_payload->>'nguoiDeNghi', v_actor.name),
    v_doi_tuong.id,
    v_doi_tuong.ten_doi_tuong,
    p_payload->>'noiDung',
    coalesce(p_payload->>'dieuKhoanTT', v_doi_tuong.dieu_khoan_tt_mac_dinh),
    v_status,
    v_actor.id,
    p_payload->>'ghiChu'
  )
  returning id into v_proposal_id;

  for v_line in select * from jsonb_array_elements(p_payload->'lines')
  loop
    v_qty := parse_number(v_line->>'slDat');
    v_price := parse_number(v_line->>'donGia');
    if coalesce(trim(v_line->>'matHang'), '') = '' or v_qty is null or v_price is null then
      continue; -- mirrors the `.filter(...)` in apiCreateProposal that silently drops incomplete lines
    end if;
    v_vat := parse_vat_rate(v_line->>'vat');
    perform ensure_material(v_line->>'matHang');
    insert into proposal_lines (ma_line, proposal_id, mat_hang, sl_dat, don_gia_chua_vat, vat_rate, thanh_tien_sau_vat, ghi_chu, trang_thai)
    values (
      next_code('DXL'), v_proposal_id, trim(v_line->>'matHang'), v_qty, v_price, v_vat,
      round(v_qty * v_price * (1 + v_vat), 2), v_line->>'ghiChu', v_status
    );
    v_line_count := v_line_count + 1;
  end loop;

  if v_line_count = 0 then
    -- Roll back: nothing usable was submitted. Raising inside a function body
    -- aborts the whole transaction, so the proposal header insert above is
    -- undone too — mirrors "Đề xuất cần ít nhất một dòng..." in the GAS code.
    raise exception 'Đề xuất cần ít nhất một dòng vật tư có mặt hàng, số lượng và đơn giá.';
  end if;

  select jsonb_build_object('MaDeXuat', ma_de_xuat, 'TrangThai', trang_thai) into v_header
  from proposals where id = v_proposal_id;

  perform write_audit(v_actor, 'CREATE_PROPOSAL', 'proposals', v_ma_de_xuat, null, v_header, 'OK', v_status);
  return jsonb_build_object('ok', true, 'maDeXuat', v_ma_de_xuat, 'status', v_status);
end;
$$;

create or replace function rpc_get_pending_proposals(p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rows jsonb;
begin
  perform require_permission('proposal:approve');
  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_rows
  from (
    select
      p.created_at,
      jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat,
        'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'TenDoiTuong', p.ten_doi_tuong,
        'NoiDung', p.noi_dung,
        'DieuKhoanTT', p.dieu_khoan_tt,
        'NguoiDeNghi', p.nguoi_de_nghi,
        'TrangThai', p.trang_thai,
        'lines', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'MaLine', l.ma_line, 'MatHang', l.mat_hang, 'SLDat', l.sl_dat,
            'DonGiaChuaVAT', l.don_gia_chua_vat, 'VATRate', l.vat_rate,
            'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu
          )), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id
        )
      ) as row_data
    from proposals p
    where p.trang_thai = 'Chờ duyệt'
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) x;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

create or replace function rpc_approve_proposal(p_ma_de_xuat text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_proposal proposals;
  v_line proposal_lines;
  v_row_count int := 0;
  v_now date := current_date;
  v_new_debt_id uuid;
begin
  v_actor := require_permission('proposal:approve');

  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then
    raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat;
  end if;
  if v_proposal.trang_thai not in ('Chờ duyệt', 'Nháp') then
    raise exception 'Đề xuất % không ở trạng thái có thể duyệt.', p_ma_de_xuat;
  end if;

  for v_line in select * from proposal_lines where proposal_id = v_proposal.id
  loop
    insert into debts (
      ma_cn, ngay_de_xuat, ngay_duyet, doi_tuong_id, ten_doi_tuong, loai_cong_no,
      proposal_id, ma_lo_hang, mat_hang, sl_dat, don_gia, vat_rate,
      dieu_khoan_tt, ghi_chu, nguon_tao
    )
    values (
      next_code('CN'), v_proposal.ngay_de_xuat, v_now, v_proposal.doi_tuong_id, v_proposal.ten_doi_tuong, 'AP',
      v_proposal.id, p_ma_de_xuat || '-' || lpad((v_row_count + 1)::text, 2, '0'), v_line.mat_hang, v_line.sl_dat,
      v_line.don_gia_chua_vat, v_line.vat_rate,
      v_proposal.dieu_khoan_tt, format('WebApp | Nội dung: %s | Ghi chú: %s', coalesce(v_proposal.noi_dung, ''), coalesce(v_line.ghi_chu, '')),
      'WebApp'
    )
    returning id into v_new_debt_id;
    v_row_count := v_row_count + 1;
    update proposal_lines set trang_thai = 'Đã duyệt', debt_id = v_new_debt_id where id = v_line.id;
  end loop;

  update proposals set trang_thai = 'Đã duyệt', nguoi_duyet = v_actor.id, approved_at = now() where id = v_proposal.id;

  perform write_audit(v_actor, 'APPROVE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal), jsonb_build_object('rows', v_row_count), 'OK', 'Đã duyệt và chuyển sang công nợ.');
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

  update proposals
  set trang_thai = 'Từ chối', nguoi_duyet = v_actor.id, approved_at = now(),
      ghi_chu = coalesce(p_reason, ghi_chu)
  where id = v_proposal.id;

  perform write_audit(v_actor, 'REJECT_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal), jsonb_build_object('reason', p_reason), 'OK', p_reason);
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

grant execute on function rpc_create_proposal(jsonb) to authenticated;
grant execute on function rpc_get_pending_proposals(int) to authenticated;
grant execute on function rpc_approve_proposal(text) to authenticated;
grant execute on function rpc_reject_proposal(text, text) to authenticated;
