-- ============================================================================
-- Run this ONCE, by hand, in the Supabase SQL Editor — AFTER:
--   1. all files in supabase/migrations/ have been run, and
--   2. you have created your first Auth user
--      (Dashboard -> Authentication -> Users -> Add user -> "Auto Confirm User").
--
-- This is not a migration (it is not in supabase/migrations/) because it is
-- specific to your project — you must paste in your own values below.
-- It plays the same role as the one-time seedAuthSheetIfEmpty_() bootstrap
-- row in the original webapp.gs (which pre-created a single Admin login).
-- ============================================================================

-- 1) Find the uid Supabase assigned to the Auth user you just created.
--    Copy the "id" value from this query's result into step 2 below.
select id, email from auth.users order by created_at desc limit 5;

-- 2) Create the matching profile row. Replace the 4 placeholders.
insert into profiles (id, email, name, role, status)
values (
  'PASTE-THE-AUTH-USER-UUID-HERE',
  'admin@yourcompany.com',
  'Admin',
  'Admin',
  'Hoạt động'
)
on conflict (id) do update set
  email = excluded.email,
  name = excluded.name,
  role = excluded.role,
  status = excluded.status;

-- 3) (Optional) Add more staff the same way, once you know their auth.users id:
-- insert into profiles (id, email, name, role, status) values
--   ('...uuid...', 'sales@yourcompany.com',   'Nguyễn Văn A', 'NhanVienMuaHang', 'Hoạt động'),
--   ('...uuid...', 'manager@yourcompany.com', 'Trần Thị B',   'TruongPhong',     'Hoạt động'),
--   ('...uuid...', 'ketoan@yourcompany.com',  'Lê Văn C',     'KeToanCongNo',    'Hoạt động'),
--   ('...uuid...', 'director@yourcompany.com','Phạm Thị D',   'LanhDao',         'Hoạt động');
--
-- Allowed roles: NhanVienMuaHang, TruongPhong, KeToanCongNo, LanhDao, Admin
