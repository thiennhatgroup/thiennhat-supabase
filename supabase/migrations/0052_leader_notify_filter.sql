-- ============================================================================
-- 0052_leader_notify_filter.sql  (Đợt H)
--  Lọc thông báo cho lãnh đạo: Chủ tịch nhận MỌI đề xuất đã trình; Tổng giám
--  đốc CHỈ nhận khoản < ngưỡng (thuộc thẩm quyền của mình). Thông báo kèm số
--  tiền. Không gửi lãnh đạo thông báo trả lại (đã chỉ báo người lập).
-- ============================================================================

create or replace function trg_proposals_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_total numeric; v_threshold numeric; v_msg text;
begin
  if (TG_OP = 'INSERT' and NEW.trang_thai = 'Chờ duyệt')
     or (TG_OP = 'UPDATE' and NEW.trang_thai = 'Chờ duyệt' and NEW.trang_thai is distinct from OLD.trang_thai) then
    select coalesce(sum(thanh_tien_sau_vat), 0) into v_total from proposal_lines where proposal_id = NEW.id;
    select coalesce((value #>> '{}')::numeric, 10000000) into v_threshold from app_config where key = 'approval_threshold';
    v_msg := NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong, '')
             || case when NEW.bo_phan is not null then ' · ' || NEW.bo_phan else '' end
             || ' · ' || to_char(v_total, 'FM999,999,999') || 'đ';
    -- Chủ tịch: mọi khoản đã trình
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    select id, 'proposal_pending', 'Đề xuất mua hàng chờ duyệt', v_msg, 'approve', NEW.ma_de_xuat
    from profiles where role = 'ChuTich' and status = 'Hoạt động';
    -- Tổng giám đốc: chỉ khoản thuộc thẩm quyền (< ngưỡng)
    if v_total < v_threshold then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'proposal_pending', 'Đề xuất mua hàng chờ duyệt', v_msg, 'approve', NEW.ma_de_xuat
      from profiles where role = 'TongGiamDoc' and status = 'Hoạt động';
    end if;
  elsif TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    if NEW.trang_thai = 'Đã duyệt' and NEW.nguoi_tao is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_tao, 'proposal_approved', 'Đề xuất đã được duyệt',
              NEW.ma_de_xuat || ' đã duyệt — sẵn sàng nghiệm thu.', 'receipt', NEW.ma_de_xuat);
    elsif NEW.trang_thai = 'Từ chối' and NEW.nguoi_tao is not null then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      values (NEW.nguoi_tao, 'proposal_rejected', 'Đề xuất bị từ chối / hủy duyệt',
              NEW.ma_de_xuat || ': ' || coalesce(NEW.ghi_chu, ''), 'proposal', NEW.ma_de_xuat);
    end if;
  end if;
  return NEW;
end;
$$;
