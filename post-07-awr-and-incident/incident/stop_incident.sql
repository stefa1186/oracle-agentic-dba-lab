-- =============================================================================
-- stop_incident.sql  (run by 02_create_incident.sh before setup, and by
-- 99_cleanup.sh; as SYSDBA)
--
-- Ends the incident: kills every session of &shop_schema in FREEPDB1 (their
-- open transactions roll back), then waits until none is left, because KILL
-- SESSION returns before the session is actually gone (at most 60 s, then an
-- error). Changes nothing else. Safe when there is nothing to stop.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Plain output: no substitution echo, no feedback.
set verify off feedback off heading off pagesize 0 serveroutput on
alter session set container = FREEPDB1;

-- 1. Kill its sessions, and count them.
declare
    l_n pls_integer := 0;
begin
    for s in (select sid, serial# from v$session where username = '&shop_schema') loop
        begin
            execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
            l_n := l_n + 1;
        exception
            -- ORA-00030: the session is already gone. Fine.
            when others then if sqlcode != -30 then raise; end if;
        end;
    end loop;
    dbms_output.put_line('KILLED=' || l_n);
end;
/

-- 2. Wait until no session is left.
declare
    l_left pls_integer;
begin
    for i in 1 .. 60 loop
        select count(*) into l_left from v$session where username = '&shop_schema';
        exit when l_left = 0;
        dbms_session.sleep(1);
    end loop;
    if l_left > 0 then
        raise_application_error(-20001, l_left || ' &shop_schema session(s) still connected after 60 s');
    end if;
end;
/

-- Marker: the shell checks for it.
select 'INCIDENT_STOPPED' from dual;
exit
