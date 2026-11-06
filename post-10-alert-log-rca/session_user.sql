-- =============================================================================
-- session_user.sql  (one incident session per shop user, started by
-- 02_create_incident.sh after the deadlock)
--
-- A user placing an order for item 42: reserves it, and waits behind the
-- stuck order entry session like everyone else. What the users report as
-- "the shop is frozen".
-- Connects as the application user; &shop_pwd arrives through stdin.
-- =============================================================================

-- Stop at the first unexpected error, with a non-zero exit code for the shell,
-- and ROLLBACK: SQL*Plus would otherwise COMMIT on exit.
whenever sqlerror exit failure rollback
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0
connect &shop_schema/"&shop_pwd"@//localhost:1521/FREEPDB1
-- What a DBA sees in V$SESSION and ASH.
exec dbms_application_info.set_module('SHOP order entry', 'reserve item')
-- The block, without comments inside (they would be in V$SQL for the agent):
--   update stock ... : reserve item 42: waits for the lock order entry holds
--   rollback         : reached only when the incident is over (a lab: undo it)
begin
    update stock set qty = qty - 1 where item_id = 42;
    rollback;
end;
/
select 'SESSION_DONE' from dual;
exit
