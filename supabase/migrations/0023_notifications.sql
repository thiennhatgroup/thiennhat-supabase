-- ============================================================================
-- 0023_notifications.sql
-- Per-user in-app notifications. Each user sees notifications for events on
-- their own documents + cross-department actions relevant to their role.
-- Emitted by triggers (not RPCs) so every code path is covered automatically.
-- `man_hinh` is the screen id the frontend navigates to (the pending action).
-- ============================================================================

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  to_user uuid not null references profiles (id) on delete cascade,
  loai text not null,
  tieu_de text not null,
  noi_dung text,
  man_hinh text,
  ref_id text,
  da_doc boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_notif_user on notifications (to_user, da_doc, created_at desc);

alter table notifications enable row level security;
revoke all on notifications from anon, authenticated;

-- ---- proposals: submit -> approvers; decision -> creator --------------------
create or replace function trg_proposals_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.trang_thai = 'Chờ duyệt' then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'proposal_pending', 'Đề xuất mua hàng chờ duyệt',
             NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong,''), 'approve', NEW.ma_de_xuat
      from profiles where role = 'LanhDao' and status = 'Hoạt động';
    end if;
  elsif TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    if NEW.trang_thai = 'Chờ duyệt' then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'proposal_pending', 'Đề xuất gửi lại chờ duyệt',
             NEW.ma_de_xuat || ' — ' || coalesce(NEW.ten_doi_tuong,''), 'approve', NEW.ma_de_xuat
      from profiles where role = 'LanhDao' and status = 'Hoạt động';
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

create or replace trigger trg_proposals_notify_aiu
  after insert or update on proposals for each row execute function trg_proposals_notify();

-- ---- payment_requests: submit -> approvers; decision -> creator -------------
create or replace function trg_payreq_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.trang_thai = 'Chờ duyệt' then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'payreq_pending', 'Đề xuất thanh toán chờ duyệt', NEW.ma_de_xuat_tt, 'payapprove', NEW.ma_de_xuat_tt
      from profiles where role = 'LanhDao' and status = 'Hoạt động';
    end if;
  elsif TG_OP = 'UPDATE' and NEW.trang_thai is distinct from OLD.trang_thai then
    if NEW.trang_thai = 'Chờ duyệt' then
      insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
      select id, 'payreq_pending', 'Đề xuất thanh toán chờ duyệt', NEW.ma_de_xuat_tt, 'payapprove', NEW.ma_de_xuat_tt
      from profiles where role = 'LanhDao' and status = 'Hoạt động';
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

create or replace trigger trg_payreq_notify_aiu
  after insert or update on payment_requests for each row execute function trg_payreq_notify();

-- ---- goods accepted -> accountants (a payable is ready) --------------------
create or replace function trg_debt_accept_notify() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if TG_OP = 'UPDATE' and OLD.sl_thuc_nhan is null and NEW.sl_thuc_nhan is not null then
    insert into notifications (to_user, loai, tieu_de, noi_dung, man_hinh, ref_id)
    select id, 'goods_accepted', 'Có khoản đã nghiệm thu',
           NEW.ma_cn || ' — ' || coalesce(NEW.ten_doi_tuong,'') || ' sẵn sàng đề xuất thanh toán.', 'payreq', NEW.ma_cn
    from profiles where role = 'KeToanCongNo' and status = 'Hoạt động';
  end if;
  return NEW;
end;
$$;

create or replace trigger trg_debt_accept_notify_u
  after update on debts for each row execute function trg_debt_accept_notify();
