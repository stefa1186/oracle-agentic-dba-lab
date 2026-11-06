-- =============================================================================
-- dba_checklist.sql  (run by 03_dba_checklist.sh, as SYSDBA)
--
-- My own health check, condensed to what can be checked with a query and an
-- explicit threshold. Read-only: it changes nothing.
--
-- One line per result:
--   FINDING | <category> | <object> | <what is wrong>
--   OK      | <category> | -        | <what was checked>
-- Categories: STORAGE, OBJECTS, STATS, SECURITY, BACKUP, MEMORY (the same
-- ones the agent is asked to use, so the two can be compared line by line).
--
-- It reads only the views in post 03's granted_views.txt plus
-- health_check_views.txt: the agent can see everything this script sees.
-- Substitution variables (&ts_warn, ...) are defined by lib.sh.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Plain output: no substitution echo, no feedback, wide lines.
set verify off feedback off heading off pagesize 0 linesize 300 trimspool on
-- No tabs: SQL*Plus would otherwise replace runs of spaces with tab characters.
set tab off
-- The pluggable database the agent works in.
alter session set container = FREEPDB1;
-- DBMS_OUTPUT belongs to the container session: enable it after the switch.
set serveroutput on size unlimited

declare
    -- Findings in the current check, so a check with none can say OK.
    l_found pls_integer;

    -- Print one finding and count it.
    procedure finding(p_cat varchar2, p_obj varchar2, p_what varchar2) is
    begin
        dbms_output.put_line(rpad('FINDING', 7) || ' | ' || rpad(p_cat, 8) || ' | ' || p_obj || ' | ' || p_what);
        l_found := l_found + 1;
    end;

    -- Print OK if the check that just ran found nothing, then reset the counter.
    procedure ok_if_none(p_cat varchar2, p_what varchar2) is
    begin
        if l_found = 0 then
            dbms_output.put_line(rpad('OK', 7) || ' | ' || rpad(p_cat, 8) || ' | - | ' || p_what);
        end if;
        l_found := 0;
    end;
begin
    l_found := 0;

    -- ======================================================================
    -- STORAGE
    -- ======================================================================
    -- 1. Permanent and undo tablespaces at or above the threshold. Used space
    --    is measured against the maximum size, so an autoextending file with
    --    room to grow is not "full". Temporary tablespaces are a separate topic.
    for r in (
        select f.tablespace_name,
               round((f.bytes - nvl(s.bytes, 0)) / f.max_bytes * 100, 1) pct,
               f.autoext
        from   (select tablespace_name,
                       sum(bytes) bytes,
                       -- Maximum size: MAXBYTES for autoextending files, else the current size.
                       sum(case when autoextensible = 'YES' then greatest(maxbytes, bytes) else bytes end) max_bytes,
                       max(autoextensible) autoext
                from   dba_data_files group by tablespace_name) f
        left join (select tablespace_name, sum(bytes) bytes from dba_free_space group by tablespace_name) s
               on s.tablespace_name = f.tablespace_name
        where  (f.bytes - nvl(s.bytes, 0)) / f.max_bytes * 100 >= &ts_warn
        order  by 2 desc
    ) loop
        finding('STORAGE', r.tablespace_name,
                'tablespace ' || to_char(r.pct, 'fm990.0') || '% used of its maximum size, autoextend '
                || case r.autoext when 'YES' then 'on' else 'off' end);
    end loop;
    ok_if_none('STORAGE', 'no tablespace at or above &ts_warn.% of its maximum size');

    -- 2. Recovery area usage, net of what the database can reclaim on its own.
    for r in (
        select name,
               round((space_used - space_reclaimable) / space_limit * 100, 1) pct
        from   v$recovery_file_dest
        where  space_limit > 0
        and    (space_used - space_reclaimable) / space_limit * 100 >= &fra_warn
    ) loop
        finding('STORAGE', 'RECOVERY AREA', 'recovery area ' || to_char(r.pct, 'fm990.0')
                || '% used, net of reclaimable space (' || r.name || ')');
    end loop;
    ok_if_none('STORAGE', 'recovery area below &fra_warn.% used, or not configured');

    -- ======================================================================
    -- OBJECTS
    -- ======================================================================
    -- 3. Invalid objects in application schemas, one line each.
    for r in (
        select o.owner, o.object_name, o.object_type
        from   dba_objects o
        join   dba_users u on u.username = o.owner and u.oracle_maintained = 'N'
        where  o.status = 'INVALID'
        order  by o.owner, o.object_name
    ) loop
        finding('OBJECTS', r.owner || '.' || r.object_name, lower(r.object_type) || ' INVALID');
    end loop;
    ok_if_none('OBJECTS', 'no invalid objects in application schemas');

    -- 4. Invalid objects in Oracle's own schemas, one line per owner.
    for r in (
        select o.owner, count(*) n
        from   dba_objects o
        join   dba_users u on u.username = o.owner and u.oracle_maintained = 'Y'
        where  o.status = 'INVALID'
        group  by o.owner
        order  by o.owner
    ) loop
        finding('OBJECTS', r.owner, r.n || ' invalid object(s) in an Oracle-maintained schema');
    end loop;
    ok_if_none('OBJECTS', 'no invalid objects in Oracle-maintained schemas');

    -- 5. Unusable indexes in application schemas.
    for r in (
        select i.owner, i.index_name
        from   dba_indexes i
        join   dba_users u on u.username = i.owner and u.oracle_maintained = 'N'
        where  i.status = 'UNUSABLE'
        order  by i.owner, i.index_name
    ) loop
        finding('OBJECTS', r.owner || '.' || r.index_name, 'index UNUSABLE');
    end loop;
    ok_if_none('OBJECTS', 'no unusable indexes in application schemas');

    -- ======================================================================
    -- STATS
    -- ======================================================================
    -- 6. Stale or missing table statistics in application schemas.
    for r in (
        select s.owner, s.table_name, s.stale_stats, s.last_analyzed, s.stattype_locked
        from   dba_tab_statistics s
        join   dba_users u on u.username = s.owner and u.oracle_maintained = 'N'
        where  s.object_type = 'TABLE'
        and    (s.stale_stats = 'YES' or s.last_analyzed is null)
        order  by s.owner, s.table_name
    ) loop
        finding('STATS', r.owner || '.' || r.table_name,
                case when r.last_analyzed is null then 'statistics missing' else 'statistics stale' end
                || case when r.stattype_locked is not null then ' (locked: ' || r.stattype_locked || ')' end);
    end loop;
    ok_if_none('STATS', 'no stale or missing table statistics in application schemas');

    -- ======================================================================
    -- SECURITY
    -- ======================================================================
    -- 7. Application accounts holding the DBA role.
    for r in (
        select p.grantee
        from   dba_role_privs p
        join   dba_users u on u.username = p.grantee and u.oracle_maintained = 'N'
        where  p.granted_role = 'DBA'
        order  by p.grantee
    ) loop
        finding('SECURITY', r.grantee, 'non-Oracle account with the DBA role');
    end loop;
    ok_if_none('SECURITY', 'no application account holds the DBA role');

    -- 8. Open accounts that still have a default password.
    for r in (
        select d.username
        from   dba_users_with_defpwd d
        join   dba_users u on u.username = d.username
        where  u.account_status = 'OPEN'
        order  by d.username
    ) loop
        finding('SECURITY', r.username, 'open account with a default password');
    end loop;
    ok_if_none('SECURITY', 'no open account with a default password');

    -- ======================================================================
    -- BACKUP (and the files recovery depends on)
    -- ======================================================================
    -- 9. Archiving: without it, no point-in-time recovery and no online backups.
    for r in (select log_mode from v$database where log_mode <> 'ARCHIVELOG') loop
        finding('BACKUP', 'LOG_MODE', 'database in ' || r.log_mode || ' mode');
    end loop;
    ok_if_none('BACKUP', 'database in ARCHIVELOG mode');

    -- 10. A successful RMAN backup within the allowed age.
    for r in (
        select max(end_time) last_ok
        from   v$rman_backup_job_details
        where  status = 'COMPLETED'
        having max(end_time) is null or max(end_time) < sysdate - &backup_days
    ) loop
        finding('BACKUP', 'RMAN BACKUPS',
                case when r.last_ok is null then 'no successful RMAN backup recorded'
                     else 'last successful RMAN backup ' || to_char(r.last_ok, 'YYYY-MM-DD HH24:MI') end);
    end loop;
    ok_if_none('BACKUP', 'a successful RMAN backup in the last &backup_days days');

    -- 11. Redo log groups with a single member: one lost file, one lost group.
    for r in (select group#, members from v$log where members < 2 order by group#) loop
        finding('BACKUP', 'REDO GROUP ' || r.group#, 'redo log group with ' || r.members || ' member (not multiplexed)');
    end loop;
    ok_if_none('BACKUP', 'every redo log group has at least 2 members');

    -- 12. Control files: fewer than two copies.
    for r in (select count(*) n from v$controlfile having count(*) < 2) loop
        finding('BACKUP', 'CONTROL FILES', r.n || ' control file (not multiplexed)');
    end loop;
    ok_if_none('BACKUP', 'at least 2 control files');

    -- ======================================================================
    -- MEMORY
    -- ======================================================================
    -- 13. PGA over-allocation: the target was too small to honour at least once.
    for r in (select value from v$pgastat where name = 'over allocation count' and value > 0) loop
        finding('MEMORY', 'PGA', 'PGA over allocation count ' || r.value || ' (PGA_AGGREGATE_TARGET too small)');
    end loop;
    ok_if_none('MEMORY', 'no PGA over-allocation since startup');
end;
/

-- Marker: the shell checks for it.
select 'CHECKLIST_COMPLETE' from dual;
exit
