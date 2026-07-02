-- ============================================================================
-- cleanup_dummy_data.sql — XÓA TOÀN BỘ DỮ LIỆU DUMMY (an toàn khóa ngoại)
--
-- Cách chạy: Supabase → SQL Editor → dán cả file → Run.
-- Xóa theo ĐÚNG THỨ TỰ để không vướng ràng buộc khóa ngoại (FK).
-- QUAN TRỌNG: xác định công nợ dummy theo CẢ tiền tố mã (CN-DUMMY-%) LẪN
--   liên kết proposal_id tới phiếu dummy — vì phiếu DX-DUMMY được duyệt qua app
--   sẽ sinh công nợ mã thật (CN-2026...), không có tiền tố DUMMY.
-- Bọc trong transaction: có lỗi sẽ tự hủy, không xóa nửa vời.
-- ============================================================================

begin;

-- Tập công nợ dummy = mã CN-DUMMY-% HOẶC thuộc phiếu DX-DUMMY-%
-- (dùng lại nhiều lần qua subquery bên dưới)

-- 1) Dòng đề xuất thanh toán tham chiếu công nợ/PR dummy
delete from payment_request_lines
 where request_id in (select id from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%')
    or debt_id in (
      select id from debts
      where ma_cn like 'CN-DUMMY-%'
         or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%'));

delete from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%';

-- 2) Phân bổ thanh toán & phiếu chi liên quan công nợ dummy
delete from payment_allocations
 where ma_cn like 'CN-DUMMY-%'
    or debt_id in (
      select id from debts
      where ma_cn like 'CN-DUMMY-%'
         or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%'))
    or payment_id in (select id from payments where ma_thanh_toan like 'TT-DUMMY-%');

delete from payments
 where ma_thanh_toan like 'TT-DUMMY-%'
    or ma_cn in (
      select ma_cn from debts
      where ma_cn like 'CN-DUMMY-%'
         or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%'));

-- 3) Gỡ tham chiếu proposal_lines -> debts (FK gây lỗi "Unable to delete row")
update proposal_lines set debt_id = null
 where debt_id in (
   select id from debts
   where ma_cn like 'CN-DUMMY-%'
      or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%'));

-- 4) Xóa công nợ dummy (theo mã HOẶC theo liên kết phiếu dummy)
delete from debts
 where ma_cn like 'CN-DUMMY-%'
    or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%');

-- 5) Xóa dòng + phiếu đề xuất dummy
delete from proposal_lines
 where ma_line like 'DXL-DUMMY-%'
    or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%');
delete from proposals where ma_de_xuat like 'DX-DUMMY-%';

-- 6) Thông báo dummy
delete from notifications where ref_id like '%DUMMY%';

-- Kiểm tra còn sót
select 'proposals'   as bang, count(*) from proposals   where ma_de_xuat   like 'DX-DUMMY-%'
union all select 'debts (mã/ liên kết)', (
    select count(*) from debts where ma_cn like 'CN-DUMMY-%'
       or proposal_id in (select id from proposals where ma_de_xuat like 'DX-DUMMY-%'))
union all select 'payment_requests',   count(*) from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%'
union all select 'payments',           count(*) from payments        where ma_thanh_toan like 'TT-DUMMY-%';

commit;   -- Đổi thành ROLLBACK; nếu chỉ muốn xem trước, chưa xóa thật.
