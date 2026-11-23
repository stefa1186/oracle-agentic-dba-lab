-- =============================================================================
-- stop_workload.sql  (run by 02_generate_load.sh before setup, and by
-- 99_cleanup.sh; as SYSDBA)
--
-- Ends everything of the workload user &awr_schema still active in FREEPDB1,
-- so the user can be dropped (ORA-01940 otherwise):
--   1. scheduler jobs it owns (from an earlier, job-based version of this
--      post) are DISABLED first, so stopping one can't let the next queued
--      one start, then the running ones are stopped
--   2. its sessions are killed
--   3. wait until no session is left: KILL SESSION returns before the
--      session is actually gone (at most 60 s, then an error)
-- Changes nothing else. Safe when there is nothing to stop.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Plain output: no substitution echo, no feedback.
set verify off feedback off heading off pagesize 0
alter session set container = FREEPDB1;

begin
    -- 1a. No queued job may start from here on.
    for j in (select job_name from dba_scheduler_jobs where owner = '&awr_schema' and enabled = 'TRUE') loop
        dbms_scheduler.disable('"&awr_schema"."' || j.job_name || '"', force => true);
    end loop;
    -- 1b. The running ones are stopped.
    for j in (select job_name from dba_scheduler_running_jobs where owner = '&awr_schema') loop
        begin
            dbms_scheduler.stop_job('"&awr_schema"."' || j.job_name || '"', force => true);
        exception
            -- ORA-27366: the job is not running (it ended in the meantime). Fine.
            when others then if sqlcode != -27366 then raise; end if;
        end;
    end loop;
    -- 2. Its sessions, whatever started them.
    for s in (select sid, serial# from v$session where username = '&awr_schema') loop
        begin
            execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
        exception
            -- ORA-00030: the session is already gone. Fine.
            when others then if sqlcode != -30 then raise; end if;
        end;
    end loop;
end;
/

-- 3. Wait until no session is left.
declare
    l_left pls_integer;
begin
    for i in 1 .. 60 loop
        select count(*) into l_left from v$session where username = '&awr_schema';
        exit when l_left = 0;
        dbms_session.sleep(1);
    end loop;
    if l_left > 0 then
        raise_application_error(-20001, l_left || ' &awr_schema session(s) still connected after 60 s');
    end if;
end;
/

-- Marker: the shell checks for it.
select 'WORKLOAD_STOPPED' from dual;
exit
