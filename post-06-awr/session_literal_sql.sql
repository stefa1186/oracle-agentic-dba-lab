-- =============================================================================
-- session_literal_sql.sql  (one workload session, started by 02_generate_load.sh)
--
-- Problem 2, hard parsing: runs the same query on ORDERS for &load_seconds
-- seconds, with a NEW literal every time and no bind variable, so no cursor
-- is ever reused: every execution is a hard parse.
-- Connects as the application user; &awr_pwd arrives through stdin.
-- =============================================================================

-- Stop at the first error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 serveroutput on
connect &awr_schema/"&awr_pwd"@//localhost:1521/FREEPDB1
-- What a DBA sees in V$SESSION and in AWR: which part of the workload this is.
exec dbms_application_info.set_module('post06 workload', 'literal sql &session_no')
declare
    l_end date := sysdate + &load_seconds / 86400;
    l_n   number;
    l_i   pls_integer := 0;
begin
    while sysdate < l_end loop
        l_i := l_i + 1;
        -- The literal changes every time: a new SQL text, a new cursor, a hard parse.
        execute immediate
            'select count(*) from orders where customer_id = ' || to_char(&session_no * 10000000 + l_i)
            into l_n;
    end loop;
    dbms_output.put_line('literal sql &session_no: ' || l_i || ' executions');
end;
/
select 'SESSION_DONE' from dual;
exit
