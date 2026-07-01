-- ============================================================================
-- 0015_proposal_plan_and_roles.sql  (Redesign Đợt 1)
--  * proposals: distinguish Mua hàng vs Tạm ứng, and capture the weekly-spend
--    plan flag + off-plan justification that leadership uses to approve.
--  * Move proposal approval/rejection from TruongPhong to LanhDao (leadership),
--    per the confirmed workflow "lãnh đạo duyệt hằng ngày".
-- Idempotent: add-column guards, delete-then-insert for permissions.
-- ============================================================================

alter table proposals add column if not exists loai_de_xuat text not null default 'MuaHang';
alter table proposals add column if not exists trong_ke_hoach_tuan boolean not null default false;
alter table proposals add column if not exists giai_trinh_ngoai_ke_hoach text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chk_proposals_loai') then
    alter table proposals add constraint chk_proposals_loai
      check (loai_de_xuat in ('MuaHang','TamUng'));
  end if;
end $$;

-- Approval authority -> LanhDao only.
delete from role_permissions
  where role = 'TruongPhong' and permission in ('proposal:approve','proposal:reject');

insert into role_permissions (role, permission) values
  ('LanhDao', 'proposal:approve'),
  ('LanhDao', 'proposal:reject')
on conflict (role, permission) do nothing;
