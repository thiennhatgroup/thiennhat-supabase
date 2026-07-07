-- ============================================================================
-- payment_path_retirement.sql -- rollback-safe check for retired batch payment.
--
-- Cách chạy: mở Supabase -> SQL Editor -> dán toàn bộ file -> Run.
-- Script kiểm tra interface RPC thật và kết thúc bằng ROLLBACK.
-- ============================================================================

begin;

create temp table _r (
  id serial,
  buoc text,
  ky_vong text,
  thuc_te text,
  ket_qua text
) on commit drop;

do $test$
declare
  v_ok boolean;
  v_err text;
begin
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '1. Signature cũ rpc_execute_payment_request(text)',
    'Không còn tồn tại',
    coalesce(to_regprocedure('rpc_execute_payment_request(text)')::text, '(null)'),
    case when to_regprocedure('rpc_execute_payment_request(text)') is null then 'PASS' else 'FAIL' end
  );

  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '2. Signature batch rpc_execute_payment_request(text,jsonb)',
    'Không còn tồn tại',
    coalesce(to_regprocedure('rpc_execute_payment_request(text,jsonb)')::text, '(null)'),
    case when to_regprocedure('rpc_execute_payment_request(text,jsonb)') is null then 'PASS' else 'FAIL' end
  );

  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '3. Interface thủ quỹ theo từng dòng',
    'rpc_cashier_pay_line(uuid,jsonb,numeric,text) vẫn tồn tại',
    coalesce(to_regprocedure('rpc_cashier_pay_line(uuid,jsonb,numeric,text)')::text, '(null)'),
    case when to_regprocedure('rpc_cashier_pay_line(uuid,jsonb,numeric,text)') is not null then 'PASS' else 'FAIL' end
  );

  v_ok := true;
  v_err := null;
  begin
    execute 'select rpc_execute_payment_request($1)' using 'DTT-SIM-RETIRED';
  exception
    when undefined_function then
      v_ok := false;
      v_err := sqlerrm;
    when others then
      v_ok := false;
      v_err := sqlerrm;
  end;
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '4. Gọi stale RPC 1 tham số',
    'Bị chặn vì function không còn tồn tại',
    case when v_ok then 'RPC vẫn chạy' else v_err end,
    case when not v_ok and v_err ilike '%does not exist%' then 'PASS' else 'FAIL' end
  );

  v_ok := true;
  v_err := null;
  begin
    execute 'select rpc_execute_payment_request($1, $2)' using 'DTT-SIM-RETIRED', '[]'::jsonb;
  exception
    when undefined_function then
      v_ok := false;
      v_err := sqlerrm;
    when others then
      v_ok := false;
      v_err := sqlerrm;
  end;
  insert into _r(buoc, ky_vong, thuc_te, ket_qua)
  values (
    '5. Gọi stale RPC batch có proof',
    'Bị chặn vì function không còn tồn tại',
    case when v_ok then 'RPC vẫn chạy' else v_err end,
    case when not v_ok and v_err ilike '%does not exist%' then 'PASS' else 'FAIL' end
  );
end;
$test$;

select buoc as "Bước", ky_vong as "Kỳ vọng", thuc_te as "Thực tế", ket_qua as "Kết quả"
from _r
order by id;

rollback;
