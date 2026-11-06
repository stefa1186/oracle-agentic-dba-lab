-- =============================================================================
-- session_lock_waiter.sql  (one workload session, started by 02_generate_load.sh)
--
-- Problem 1, row lock contention, a waiter: keeps updating row 1 of ACCOUNTS
-- for &load_seconds seconds, so it spends most of its time waiting for the
-- holder (enq: TX - row lock contention).
-- Connects as the application user; &awr_pwd arrives through stdin.
-- =============================================================================

-- Stop at the first error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 serveroutput on
connect &awr_schema/"&awr_pwd"@//localhost:1521/FREEPDB1
-- What a DBA sees in V$SESSION and in AWR: which part of the workload this is.
exec dbms_application_info.set_module('post06 workload', 'lock waiter &session_no')
declare
    l_end date := sysdate + &load_seconds / 86400;
    l_updates pls_integer := 0;
begin
    while sysdate < l_end loop
        -- Waits here whenever the holder (or another waiter) has row 1.
        update accounts set balance = balance - 1 where id = 1;
        commit;
        l_updates := l_updates + 1;
    end loop;
    dbms_output.put_line('lock waiter &session_no: ' || l_updates || ' updates');
end;
/
select 'SESSION_DONE' from dual;
exit
