-- ============================================================================
-- 0019_approved_and_unapprove.sql
-- Leadership needs to (a) review every proposal already APPROVED on a chosen
-- day, and (b) reverse an approval ("hủy duyệt") with a reason.
--   rpc_get_approved_proposals(date) -> approved proposals whose approval date
--                                       matches, with lines + total.
--   rpc_unapprove_proposal(ma, reason)-> only if none of the debts it created
--                                       has been paid/allocated; deletes those
--                                       debts, resets the lines, flips status
--                                       to 'Từ chối' and records the reason so
--                                       purchasing can revise & resubmit.
-- ============================================================================

create or replace function rpc_get_approved_proposals(p_date date default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_date date := coalesce(p_date, current_date);
  v_rows jsonb;
begin
  perform require_permission('proposal:approve');
  select coalesce(jsonb_agg(row_data order by approved_at desc), '[]'::jsonb) into v_rows
  from (
    select
      p.approved_at,
      jsonb_build_object(
        'MaDeXuat', p.ma_de_xuat,
        'LoaiDeXuat', p.loai_de_xuat,
        'NgayDeXuat', to_char(p.ngay_de_xuat, 'YYYY-MM-DD'),
        'NgayDuyet', to_char(p.approved_at, 'YYYY-MM-DD HH24:MI'),
        'TenDoiTuong', p.ten_doi_tuong,
        'NoiDung', p.noi_dung,
        'NguoiDeNghi', p.nguoi_de_nghi,
        'NguoiDuyet', (select name from profiles where id = p.nguoi_duyet),
        'TrongKeHoachTuan', p.trong_ke_hoach_tuan,
        'GiaiTrinhNgoaiKeHoach', p.giai_trinh_ngoai_ke_hoach,
        'TongTien', coalesce((select sum(l.thanh_tien_sau_vat) from proposal_lines l where l.proposal_id = p.id), 0),
        -- true nếu bất kỳ công nợ phát sinh từ phiếu này đã bắt đầu được thanh toán
        'DaPhatSinhTT', exists (
          select 1 from debts d where d.proposal_id = p.id
            and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))
        ),
        'lines', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'MatHang', l.mat_hang, 'SLDat', l.sl_dat, 'DonGiaChuaVAT', l.don_gia_chua_vat,
            'VATRate', l.vat_rate, 'ThanhTienSauVAT', l.thanh_tien_sau_vat, 'GhiChu', l.ghi_chu
          ) order by l.ma_line), '[]'::jsonb)
          from proposal_lines l where l.proposal_id = p.id
        )
      ) as row_data
    from proposals p
    where p.trang_thai = 'Đã duyệt'
      and p.approved_at is not null
      and (p.approved_at at time zone 'Asia/Ho_Chi_Minh')::date = v_date
    order by p.approved_at desc
  ) x;
  return jsonb_build_object('ok', true, 'date', to_char(v_date, 'YYYY-MM-DD'), 'rows', v_rows);
end;
$$;

create or replace function rpc_unapprove_proposal(p_ma_de_xuat text, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor profiles;
  v_proposal proposals;
  v_paid boolean;
begin
  v_actor := require_permission('proposal:approve');
  if nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'Cần nhập lý do hủy duyệt để thông báo cho bộ phận mua hàng.';
  end if;

  select * into v_proposal from proposals where ma_de_xuat = p_ma_de_xuat;
  if v_proposal is null then raise exception 'Không tìm thấy đề xuất %.', p_ma_de_xuat; end if;
  if v_proposal.trang_thai <> 'Đã duyệt' then
    raise exception 'Chỉ hủy duyệt được phiếu đang ở trạng thái Đã duyệt.';
  end if;

  -- Chặn nếu công nợ đã phát sinh thanh toán — không được xóa ngược tiền đã chi.
  select exists (
    select 1 from debts d where d.proposal_id = v_proposal.id
      and (d.da_thanh_toan > 0 or exists (select 1 from payment_allocations pa where pa.debt_id = d.id))
  ) into v_paid;
  if v_paid then
    raise exception 'Không thể hủy duyệt: đã có thanh toán ghi nhận trên công nợ của phiếu này.';
  end if;

  -- Gỡ liên kết & xóa các công nợ phát sinh, đưa dòng về trạng thái chờ.
  update proposal_lines set trang_thai = 'Chờ duyệt', debt_id = null where proposal_id = v_proposal.id;
  delete from debts where proposal_id = v_proposal.id;

  update proposals
  set trang_thai = 'Từ chối', nguoi_duyet = v_actor.id, approved_at = now(),
      ghi_chu = coalesce(ghi_chu,'') || ' | HỦY DUYỆT: ' || trim(p_reason)
  where id = v_proposal.id;

  perform write_audit(v_actor, 'UNAPPROVE_PROPOSAL', 'proposals', p_ma_de_xuat, to_jsonb(v_proposal),
    jsonb_build_object('reason', p_reason), 'OK', trim(p_reason));
  return jsonb_build_object('ok', true, 'maDeXuat', p_ma_de_xuat);
end;
$$;

grant execute on function rpc_get_approved_proposals(date) to authenticated;
grant execute on function rpc_unapprove_proposal(text, text) to authenticated;
