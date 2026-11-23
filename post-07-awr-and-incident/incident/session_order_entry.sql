-- =============================================================================
-- session_order_entry.sql  (one incident session, started by 02_create_incident.sh)
--
-- The shop's order entry, with the application bug behind the incident:
--   1. reserves item 42 (locks its STOCK row)
--   2. 3 seconds later, marks order 1001 as packed (wants its ORDERS row,
--      which the invoicing batch holds: wait)
--   3. the invoicing batch now wants item 42: a deadlock. Oracle ends it by
--      rolling back ONE statement of one session with ORA-00060 (here: this
--      one, which waited first)
--   4. THE BUG: the application catches ORA-00060, logs a warning and
--      returns, with neither a commit nor a rollback. Its transaction stays
--      open, item 42 stays locked, and everyone who needs it waits
-- After this file the session is HELD (incident_session.sh): connected and
-- idle, its transaction open, until the incident time is over. Then
-- session_order_entry_end.sql ends it.
--
-- No comment INSIDE the PL/SQL block: a block's comments are part of its
-- text in V$SQL, where the agent can read them. Like a real application's
-- code, the block says what it does, not where the bug is. Its lines:
--   deadlock exception / pragma : a name for ORA-00060, to catch it alone
--   update stock ...            : reserve item 42 (row lock on STOCK)
--   dbms_session.sleep(3)       : the invoicing batch takes ORDERS 1001 meanwhile
--   update orders ...           : wants ORDERS 1001: waits, then ORA-00060
--   when deadlock then ...      : the bug: a warning, and no rollback
-- Connects as the application user; &shop_pwd arrives through stdin.
-- =============================================================================

-- Stop at the first unexpected error, with a non-zero exit code for the shell,
-- and ROLLBACK: SQL*Plus would otherwise COMMIT on exit.
whenever sqlerror exit failure rollback
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 serveroutput on
connect &shop_schema/"&shop_pwd"@//localhost:1521/FREEPDB1
-- What a DBA sees in V$SESSION and ASH: which part of the application this is.
exec dbms_application_info.set_module('SHOP order entry', 'reserve and pack')
declare
    deadlock exception;
    pragma exception_init(deadlock, -60);
begin
    update stock set qty = qty - 1 where item_id = 42;
    dbms_session.sleep(3);
    begin
        update orders set status = 'PACKED' where order_id = 1001;
    exception
        when deadlock then
            dbms_output.put_line('order entry: order 1001 not packed (deadlock), retry later');
    end;
end;
/
-- No exit here: the session stays connected (held by incident_session.sh).
