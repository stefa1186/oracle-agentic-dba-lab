-- =============================================================================
-- tuning_advisor.sql  (run by 04_tuning_advisor.sh, as SYSDBA)
--
-- Runs SQL Tuning Advisor (DBMS_SQLTUNE) on the slow query, taken from the
-- cursor cache by its SQL_ID (&sql_id), with a COMPREHENSIVE analysis of at
-- most &sta_limit seconds. Prints, between markers:
--   #REPORT_BEGIN# .. #REPORT_END#   the advisor's report (findings, recommendations)
--   #SCRIPT_BEGIN# .. #SCRIPT_END#   the advisor's own script to implement them
-- The task is named POST07_STA and replaced on every run.
-- Recommendations are NOT implemented here: 06_try_fix.sh tests them, then undoes them.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
set verify off feedback off heading off pagesize 0 linesize 300 trimspool on tab off long 1000000 longchunksize 1000000
alter session set container = FREEPDB1;

-- A previous run's task, if any.
begin
    dbms_sqltune.drop_tuning_task('POST07_STA');
exception
    -- ORA-13605: the task does not exist (first run). Anything else is real.
    when others then if sqlcode != -13605 then raise; end if;
end;
/

-- Create and run the task on the cursor in the cache.
declare
    l_task varchar2(128);
begin
    l_task := dbms_sqltune.create_tuning_task(
                  sql_id     => '&sql_id',
                  scope      => dbms_sqltune.scope_comprehensive,
                  time_limit => &sta_limit,
                  task_name  => 'POST07_STA',
                  description => 'post 07: the slow query');
    dbms_sqltune.execute_tuning_task(task_name => 'POST07_STA');
end;
/

-- The report, as the advisor writes it.
select '#REPORT_BEGIN#' from dual;
select dbms_sqltune.report_tuning_task('POST07_STA') from dual;
select '#REPORT_END#' from dual;

-- The advisor's own implementation script (indexes, SQL profile, statistics).
select '#SCRIPT_BEGIN#' from dual;
select dbms_sqltune.script_tuning_task('POST07_STA') from dual;
select '#SCRIPT_END#' from dual;
exit
