-- ============================================================================
-- cleanup_dummy_data.sql — XÓA TOÀN BỘ DỮ LIỆU DUMMY (an toàn khóa ngoại)
--
-- Cách chạy: Supabase → SQL Editor → dán cả file → Run.
-- Xóa theo ĐÚNG THỨ TỰ để không vướng ràng buộc khóa ngoại (FK).
-- Chỉ đụng tới bản ghi có tiền tố *-DUMMY-* nên không ảnh hưởng dữ liệu thật.
-- Bọc trong transaction: nếu có lỗi sẽ tự hủy, không xóa nửa vời.
-- ============================================================================

begin;

-- 1) Con của payments / debts trước
delete from payment_request_lines where request_id in (select id from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%');
delete from payment_request_lines where debt_id in (select id from debts where ma_cn like 'CN-DUMMY-%');
delete from payment_requests    where ma_de_xuat_tt like 'PT-DUMMY-%';
delete from payment_allocations where ma_cn like 'CN-DUMMY-%';
delete from payments            where ma_thanh_toan like 'TT-DUMMY-%';

-- 2) Gỡ tham chiếu proposal_lines -> debts (đây là FK gây lỗi "Unable to delete row")
update proposal_lines set debt_id = null
  where debt_id in (select id from debts where ma_cn like 'CN-DUMMY-%');

-- 3) Xóa công nợ dummy
delete from debts where ma_cn like 'CN-DUMMY-%';

-- 4) Xóa dòng + phiếu đề xuất dummy (proposal_lines có ON DELETE CASCADE theo proposals,
--    nhưng xóa tường minh cho chắc)
delete from proposal_lines where ma_line like 'DXL-DUMMY-%';
delete from proposals      where ma_de_xuat like 'DX-DUMMY-%';

-- 5) Thông báo dummy
delete from notifications where ref_id like '%DUMMY%';

-- Kiểm tra còn sót
select 'proposals'   as bang, count(*) from proposals   where ma_de_xuat   like 'DX-DUMMY-%'
union all select 'debts',              count(*) from debts           where ma_cn        like 'CN-DUMMY-%'
union all select 'payment_requests',   count(*) from payment_requests where ma_de_xuat_tt like 'PT-DUMMY-%'
union all select 'payments',           count(*) from payments        where ma_thanh_toan like 'TT-DUMMY-%';

commit;   -- Đổi thành ROLLBACK; nếu chỉ muốn xem trước, chưa xóa thật.
