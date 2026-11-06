-- =============================================================================
-- session_lock_holder.sql  (one workload session, started by 02_generate_load.sh)
--
-- Problem 1, row lock contention, the holder: locks row 1 of ACCOUNTS, keeps
-- it &lock_hold seconds, commits, and starts again, for &load_seconds seconds.
-- Connects as the application user; &awr_pwd arrives through stdin.
-- =============================================================================

-- Stop at the first error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 serveroutput on
connect &awr_schema/"&awr_pwd"@//localhost:1521/FREEPDB1
-- What a DBA sees in V$SESSION and in AWR: which part of the workload this is.
exec dbms_application_info.set_module('post06 workload', 'lock holder')
declare
    l_end date := sysdate + &load_seconds / 86400;
    l_rounds pls_integer := 0;
begin
    while sysdate < l_end loop
        -- Take the lock on row 1...
        update accounts set balance = balance + 1 where id = 1;
        -- ...keep it while everyone else queues...
        dbms_session.sleep(&lock_hold);
        -- ...and let one of them have it.
        commit;
        l_rounds := l_rounds + 1;
    end loop;
    dbms_output.put_line('lock holder: ' || l_rounds || ' lock periods');
end;
/
select 'SESSION_DONE' from dual;
exit
