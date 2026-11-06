-- =============================================================================
-- seed_known_problems.sql  (run by 02_seed_known_problems.sh, as SYSDBA)
--
-- Creates the ANSWER KEY for the health check: problems I know are there,
-- so I can tell whether the agent found them.
--   1. a tablespace nearly full, with autoextend off
--   2. a table whose statistics are stale (and locked, so the nightly
--      statistics job can't quietly fix them and change the test)
--   3. two invalid objects: a view whose table was dropped, and a procedure
--      that doesn't compile
--   4. an unusable index
--   5. a non-Oracle account holding the DBA role (schema-only: nobody can
--      log in as it)
-- Then it prints every seeded problem, read back from the dictionary.
--
-- Deterministic: everything a previous run created is dropped first, and the
-- data is generated with CONNECT BY, not random values.
-- Substitution variables (&hc_schema, ...) are defined by lib.sh.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- No "old/new" substitution echo, no feedback noise, wide lines.
set verify off feedback off heading off pagesize 0 linesize 300 trimspool on
-- No tabs: SQL*Plus would otherwise replace runs of spaces with tab characters.
set tab off
-- Everything happens inside the pluggable database.
alter session set container = FREEPDB1;
-- DBMS_OUTPUT belongs to the container session: enable it after the switch.
set serveroutput on

-- -----------------------------------------------------------------------------
-- 0. Start clean: drop what a previous seed created (absent is fine).
-- -----------------------------------------------------------------------------
begin
    -- The seeded schema and everything it owns.
    execute immediate 'drop user &hc_schema cascade';
exception
    -- ORA-01918: user does not exist (first run). Anything else is a real error.
    when others then if sqlcode != -1918 then raise; end if;
end;
/
begin
    -- The seeded privileged account.
    execute immediate 'drop user &hc_legacy cascade';
exception
    when others then if sqlcode != -1918 then raise; end if;
end;
/
begin
    -- The seeded tablespace and its datafile (only after its owner is gone).
    execute immediate 'drop tablespace &hc_ts including contents and datafiles';
exception
    -- ORA-00959: tablespace does not exist.
    when others then if sqlcode != -959 then raise; end if;
end;
/

-- -----------------------------------------------------------------------------
-- 1. The small tablespace: autoextend off, uniform 1 MB extents.
-- -----------------------------------------------------------------------------
declare
    -- Folder of this PDB's datafiles, taken from its SYSTEM datafile.
    l_dir varchar2(513);
begin
    -- Everything up to and including the last "/" of the SYSTEM datafile name.
    select substr(file_name, 1, instr(file_name, '/', -1))
    into   l_dir
    from   dba_data_files
    where  tablespace_name = 'SYSTEM';
    -- Same folder, a predictable file name: the database's own layout is kept.
    -- REUSE: a file left behind by an interrupted earlier run is overwritten.
    execute immediate 'create tablespace &hc_ts datafile '''
                   || l_dir || lower('&hc_ts') || '01.dbf'' size &hc_size_mb.M reuse autoextend off'
                   || ' extent management local uniform size 1M';
end;
/

-- -----------------------------------------------------------------------------
-- 2. The schema: schema-only (NO AUTHENTICATION), so it can own objects but
--    nobody can connect as it.
-- -----------------------------------------------------------------------------
create user &hc_schema no authentication
    default tablespace &hc_ts
    quota unlimited on &hc_ts;

-- -----------------------------------------------------------------------------
-- 3. Stale statistics: gather on 1,000 rows, then add 10,000 more.
-- -----------------------------------------------------------------------------
create table &hc_schema..hc_orders (
    id      number primary key,
    created date   not null,
    amount  number not null
);
-- 1,000 rows of predictable data.
insert into &hc_schema..hc_orders (id, created, amount)
select level, date '2026-01-01' + mod(level, 300), mod(level * 7, 1000)
from   dual connect by level <= 1000;
commit;
-- Statistics now describe 1,000 rows.
exec dbms_stats.gather_table_stats('&hc_schema', 'HC_ORDERS')
-- Ten times more rows: the statistics are now far off.
insert into &hc_schema..hc_orders (id, created, amount)
select 1000 + level, date '2026-01-01' + mod(level, 300), mod(level * 7, 1000)
from   dual connect by level <= 10000;
commit;
-- Locked: the automatic statistics job must not "fix" the test overnight.
exec dbms_stats.lock_table_stats('&hc_schema', 'HC_ORDERS')
-- Write the DML counts the database keeps in memory to the dictionary, so
-- STALE_STATS shows YES now rather than after the next automatic flush.
exec dbms_stats.flush_database_monitoring_info

-- -----------------------------------------------------------------------------
-- 4. Invalid objects.
-- -----------------------------------------------------------------------------
-- A view on a table that is then dropped: the view becomes INVALID.
create table &hc_schema..hc_tmp (n number);
create view &hc_schema..hc_orders_v as select n from &hc_schema..hc_tmp;
drop table &hc_schema..hc_tmp purge;
-- A procedure that calls something that doesn't exist: created, but INVALID.
begin
    execute immediate 'create procedure &hc_schema..hc_broken as begin hc_missing_proc; end;';
exception
    -- ORA-24344: success with compilation error. That's the point here.
    when others then if sqlcode != -24344 then raise; end if;
end;
/

-- -----------------------------------------------------------------------------
-- 5. An unusable index.
-- -----------------------------------------------------------------------------
create index &hc_schema..hc_orders_created_ix on &hc_schema..hc_orders (created);
alter index &hc_schema..hc_orders_created_ix unusable;

-- -----------------------------------------------------------------------------
-- 6. A non-Oracle account with the DBA role. Schema-only: no password, no
--    login, so the lab is no less safe. The finding is the grant itself.
-- -----------------------------------------------------------------------------
create user &hc_legacy no authentication;
grant dba to &hc_legacy;

-- -----------------------------------------------------------------------------
-- 7. Fill the small tablespace to the target, one 1 MB extent at a time.
-- -----------------------------------------------------------------------------
-- The table that takes the space, starting with one extent.
create table &hc_schema..hc_fill (pad char(2000)) tablespace &hc_ts;
-- Statistics on it now: a never-analyzed table would be a finding I didn't seed.
exec dbms_stats.gather_table_stats('&hc_schema', 'HC_FILL')
declare
    -- Size of the datafile and free space in it, in bytes.
    l_total number;
    l_free  number;
    -- Safety net: never more extents than the file has megabytes.
    l_steps pls_integer := 0;
begin
    loop
        -- Used percentage, computed from the dictionary as it is right now.
        select sum(bytes) into l_total from dba_data_files where tablespace_name = '&hc_ts';
        select nvl(sum(bytes), 0) into l_free from dba_free_space where tablespace_name = '&hc_ts';
        -- Stop as soon as the target is reached.
        exit when (l_total - l_free) / l_total * 100 >= &hc_target;
        -- Stop if the loop would run away (it never should).
        l_steps := l_steps + 1;
        exit when l_steps > &hc_size_mb;
        -- One more 1 MB extent for the fill table.
        execute immediate 'alter table &hc_schema..hc_fill allocate extent (size 1M)';
    end loop;
end;
/

-- -----------------------------------------------------------------------------
-- 8. The answer key, read back from the dictionary (not echoed: proven).
--    Format: SEEDED | <category> | <object> | <what is wrong>
-- -----------------------------------------------------------------------------
-- Used percentage from DBA_DATA_FILES and DBA_FREE_SPACE: exact at this moment,
-- the same way the loop above measured it.
select 'SEEDED | STORAGE | ' || f.tablespace_name || ' | tablespace '
       || to_char(round((f.bytes - nvl(s.bytes, 0)) / f.bytes * 100, 1), 'fm990.0')
       || '% used, autoextend off'
from   (select tablespace_name, sum(bytes) bytes from dba_data_files
        where tablespace_name = '&hc_ts' group by tablespace_name) f
left join (select tablespace_name, sum(bytes) bytes from dba_free_space
           where tablespace_name = '&hc_ts' group by tablespace_name) s
       on s.tablespace_name = f.tablespace_name;

select 'SEEDED | STATS | ' || owner || '.' || table_name || ' | statistics stale (STALE_STATS='
       || stale_stats || ', locked: ' || nvl(stattype_locked, 'no') || ')'
from   dba_tab_statistics
where  owner = '&hc_schema' and table_name = 'HC_ORDERS' and object_type = 'TABLE';

select 'SEEDED | OBJECTS | ' || owner || '.' || object_name || ' | ' || lower(object_type) || ' ' || status
from   dba_objects
where  owner = '&hc_schema' and status = 'INVALID'
order  by object_name;

select 'SEEDED | OBJECTS | ' || owner || '.' || index_name || ' | index ' || status
from   dba_indexes
where  owner = '&hc_schema' and status = 'UNUSABLE';

select 'SEEDED | SECURITY | ' || grantee || ' | non-Oracle account with the DBA role'
from   dba_role_privs
where  grantee = '&hc_legacy' and granted_role = 'DBA';

-- Marker: the shell checks for it.
select 'SEED_COMPLETE' from dual;
exit
