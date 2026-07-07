-- ============================================================================
-- 0073_retire_batch_payment_request.sql
--  Retire the stale batch payment execution RPC.
--
--  Cashier payments now go through rpc_cashier_pay_line(uuid, jsonb, numeric,
--  text), which locks a single payment_request_lines row, records proof,
--  stores actual paid amount/method, checks remaining debt balance, and marks
--  each line paid independently. Keeping rpc_execute_payment_request callable
--  would leave an alternate batch money-moving path with weaker invariants.
-- ============================================================================

drop function if exists rpc_execute_payment_request(text);
drop function if exists rpc_execute_payment_request(text, jsonb);
