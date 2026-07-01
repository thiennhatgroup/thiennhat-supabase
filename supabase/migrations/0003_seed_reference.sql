-- ============================================================================
-- 0003_seed_reference.sql
-- Mirrors WEB_ROLE_PERMISSIONS and APP_CONFIG defaults from webapp.gs.
-- Safe to re-run (ON CONFLICT DO NOTHING / DO UPDATE).
-- ============================================================================

insert into app_config (key, value) values
  ('default_vat_rate', '0.08'),
  ('timezone', '"Asia/Ho_Chi_Minh"')
on conflict (key) do nothing;

insert into role_permissions (role, permission) values
  ('NhanVienMuaHang', 'quote:read'),
  ('NhanVienMuaHang', 'quote:sync'),
  ('NhanVienMuaHang', 'proposal:create'),
  ('NhanVienMuaHang', 'proposal:submit'),
  ('NhanVienMuaHang', 'receipt:update'),
  ('NhanVienMuaHang', 'recent:read'),
  ('NhanVienMuaHang', 'dashboard:read'),

  ('TruongPhong', 'quote:read'),
  ('TruongPhong', 'proposal:approve'),
  ('TruongPhong', 'proposal:reject'),
  ('TruongPhong', 'recent:read'),
  ('TruongPhong', 'dashboard:read'),

  ('KeToanCongNo', 'quote:read'),
  ('KeToanCongNo', 'receipt:update'),
  ('KeToanCongNo', 'payment:create'),
  ('KeToanCongNo', 'settlement:preview'),
  ('KeToanCongNo', 'settlement:confirm'),
  ('KeToanCongNo', 'recent:read'),
  ('KeToanCongNo', 'dashboard:read'),

  ('LanhDao', 'quote:read'),
  ('LanhDao', 'recent:read'),
  ('LanhDao', 'dashboard:read')
  -- Admin is not listed: has_permission()/require_permission() treat role
  -- 'Admin' as "*" (all permissions) without needing rows here, exactly like
  -- WEB_ROLE_PERMISSIONS.Admin = ['*'] in webapp.gs.
on conflict (role, permission) do nothing;
