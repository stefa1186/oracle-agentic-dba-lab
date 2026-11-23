-- =============================================================================
-- session_invoicing.sql  (one incident session, started by 02_create_incident.sh,
-- 1 second after order entry)
--
-- The invoicing batch, which takes the same two rows in the OPPOSITE order:
--   1. invoices order 1001 (locks its ORDERS row)
--   2. 3 seconds later, updates the stock of item 42 (wants the STOCK row
--      order entry holds): the second half of the deadlock. Oracle rolls back
--      the other session's statement; this one keeps waiting, because order
--      entry never releases item 42
-- Connects as the application user; &shop_pwd arrives through stdin.
-- =============================================================================

-- Stop at the first unexpected error, with a non-zero exit code for the shell,
-- and ROLLBACK: SQL*Plus would otherwise COMMIT on exit.
whenever sqlerror exit failure rollback
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 serveroutput on
connect &shop_schema/"&shop_pwd"@//localhost:1521/FREEPDB1
-- What a DBA sees in V$SESSION and ASH.
exec dbms_application_info.set_module('SHOP invoicing batch', 'invoice order')
-- The block, without comments inside (they would be in V$SQL for the agent):
--   update orders ... : invoice the order (row lock on ORDERS 1001)
--   sleep(3)          : order entry meanwhile wants ORDERS 1001
--   update stock ...  : needs STOCK item 42, held by order entry: waits
--   rollback          : reached only when order entry finally ends (a lab: undo)
begin
    update orders set status = 'INVOICED' where order_id = 1001;
    dbms_session.sleep(3);
    update stock set qty = qty + 0 where item_id = 42;
    rollback;
end;
/
select 'SESSION_DONE' from dual;
exit
