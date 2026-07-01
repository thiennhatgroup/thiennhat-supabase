-- ============================================================================
-- 0005_debts_view.sql
-- v_debts recomputes, on every read, exactly the formulas that
-- setCongNoFormulasBulk_() used to bake into spreadsheet cells:
--   amountOrder   = qtyOrder * unitPrice * (1+vat)
--   amountActual  = qtyActual * unitPrice * (1+vat)   [only if qtyActual set]
--   balance       = amountActual - paid
--   overdueDays   = balance<=0 ? 0 : (dueDate is null ? 0 : max(0, today-due))
--   status        = the same nested IF chain as the sheet formula
--   canSettle     = actual>0 AND qtyActual is meaningfully set
--                   (mirrors `canSettle: actual > 0 && meaningfulValue(qtyActualRaw)`)
-- ============================================================================

create or replace view v_debts as
select
  d.*,
  round(coalesce(d.sl_dat, 0) * d.don_gia * (1 + d.vat_rate), 2) as thanh_tien_dat,
  round(case when d.sl_thuc_nhan is not null
             then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)
             else 0 end, 2) as thanh_tien_thuc_nhan,
  round(
    (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate) else 0 end)
    - d.da_thanh_toan
  , 2) as so_tien_con_lai,
  case
    when (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan <= 0 then 0
    when d.han_thanh_toan is null then 0
    else greatest(0, (current_date - d.han_thanh_toan))
  end as so_ngay_qua_han,
  case
    when d.sl_thuc_nhan is null and d.da_thanh_toan = 0 then 'Chờ SL thực nhận'
    when d.sl_thuc_nhan is null and d.da_thanh_toan > 0 then 'Đã tạm ứng, chờ SL thực nhận'
    when (case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan < 0 then 'Đã thanh toán/đối trừ'
    when abs((case when d.sl_thuc_nhan is not null then d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate) else 0 end) - d.da_thanh_toan) < 1 then 'Đã tất toán'
    when d.han_thanh_toan is null then 'Cần nhập hạn TT'
    when greatest(0, (current_date - d.han_thanh_toan)) > 0 then 'Quá hạn'
    else 'Theo dõi'
  end as trang_thai_dong,
  (d.sl_thuc_nhan is not null and (d.sl_thuc_nhan * d.don_gia * (1 + d.vat_rate)) > 0) as can_settle
from debts d;

comment on view v_debts is 'Read-only computed view over debts, replicating the 05_CONG_NO_NCC formula columns (M/N/R/S/T in the sheet).';
