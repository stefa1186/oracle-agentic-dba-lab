-- =============================================================================
-- judge_extras.sql  (run by 06_judge_extras.sh, as SYSDBA)
--
-- The facts needed to judge the agent's findings that are NOT on my checklist:
-- is each one a real problem, true but harmless, or wrong? Read-only.
--
-- One section per kind of extra finding seen in the post 05 runs:
--   1. tablespaces: free space now vs. room to grow (autoextend)
--   2. accounts with the DBA role or OPEN status: Oracle-maintained? can they log in at all?
--   3. memory parameters: the CDB's values vs. the PDB's
--   4. recovery area and archive destinations: where do archived logs go?
--   5. missing statistics: Oracle-maintained tables vs. application tables
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Readable columns, no feedback noise.
set verify off feedback off pagesize 100 linesize 200 trimspool on tab off

-- -----------------------------------------------------------------------------
-- 3a. Memory parameters at CDB level: run in the root first.
-- -----------------------------------------------------------------------------
prompt
prompt === 3a. Memory parameters in CDB$ROOT (the instance)
column name  format a24
column value format a20
select name, display_value value
from   v$parameter
where  name in ('sga_target', 'sga_max_size', 'memory_target', 'memory_max_target', 'pga_aggregate_target', 'use_large_pages')
order  by name;

-- Everything else is about the pluggable database the agent works in.
alter session set container = FREEPDB1;

prompt
prompt === 3b. The same parameters, as seen from FREEPDB1 (what the agent saw)
select name, display_value value, ispdb_modifiable
from   v$parameter
where  name in ('sga_target', 'sga_max_size', 'memory_target', 'memory_max_target', 'pga_aggregate_target')
order  by name;

-- -----------------------------------------------------------------------------
-- 1. Tablespaces: free space in the current files vs. room to grow.
-- -----------------------------------------------------------------------------
prompt
prompt === 1. Tablespaces: current size, free now, maximum size, used % of maximum
column tablespace_name format a16
column autoext         format a7
select f.tablespace_name,
       max(f.autoextensible)                                               autoext,
       round(sum(f.bytes) / 1048576, 1)                                    size_mb,
       round(nvl(max(s.free), 0) / 1048576, 2)                             free_now_mb,
       round(sum(case when f.autoextensible = 'YES'
                      then greatest(f.maxbytes, f.bytes) else f.bytes end) / 1048576, 0) max_mb,
       round((sum(f.bytes) - nvl(max(s.free), 0))
             / sum(case when f.autoextensible = 'YES' then greatest(f.maxbytes, f.bytes) else f.bytes end) * 100, 2) used_pct_of_max
from   dba_data_files f
left join (select tablespace_name, sum(bytes) free from dba_free_space group by tablespace_name) s
       on s.tablespace_name = f.tablespace_name
group  by f.tablespace_name
order  by f.tablespace_name;

-- -----------------------------------------------------------------------------
-- 2. Accounts: who holds DBA, who is OPEN, and whether they can log in at all.
--    AUTHENTICATION_TYPE NONE = schema-only (NO AUTHENTICATION): no login possible.
-- -----------------------------------------------------------------------------
prompt
prompt === 2a. Accounts holding the DBA role
column username            format a22
column account_status      format a16
column authentication_type format a10
column oracle_maintained   format a8 heading ORA_MAINT
select u.username, u.oracle_maintained, u.authentication_type, u.account_status
from   dba_role_privs p
join   dba_users u on u.username = p.grantee
where  p.granted_role = 'DBA'
order  by u.username;

prompt
prompt === 2b. OPEN accounts (Oracle-maintained first)
select username, oracle_maintained, authentication_type, account_status
from   dba_users
where  account_status = 'OPEN'
order  by oracle_maintained desc, username;

-- -----------------------------------------------------------------------------
-- 4. Recovery area and archive destinations.
-- -----------------------------------------------------------------------------
prompt
prompt === 4a. Archiving: mode, recovery area, active destinations
column dest_name   format a20
column destination format a60
select log_mode from v$database;
select name, display_value value
from   v$parameter
where  name in ('db_recovery_file_dest', 'db_recovery_file_dest_size', 'log_archive_dest_1')
order  by name;
select dest_name, status, destination
from   v$archive_dest
where  status <> 'INACTIVE';

prompt
prompt === 4b. The most recent archived log: where it actually went
column name format a90
select name, to_char(completion_time, 'YYYY-MM-DD HH24:MI') completed
from   v$archived_log
where  recid = (select max(recid) from v$archived_log);

-- -----------------------------------------------------------------------------
-- 5. Tables without statistics: Oracle's own vs. application schemas.
-- -----------------------------------------------------------------------------
prompt
prompt === 5. Tables with no statistics, by kind of schema
select u.oracle_maintained, count(*) tables_without_stats
from   dba_tab_statistics s
join   dba_users u on u.username = s.owner
where  s.object_type = 'TABLE' and s.last_analyzed is null
group  by u.oracle_maintained
order  by u.oracle_maintained;

prompt
prompt === 5b. Indexes without statistics in application schemas
column owner      format a12
column index_name format a28
column status     format a9
select i.owner, i.index_name, i.status, i.last_analyzed
from   dba_indexes i
join   dba_users u on u.username = i.owner and u.oracle_maintained = 'N'
where  i.last_analyzed is null
order  by i.owner, i.index_name;

prompt
select 'JUDGE_COMPLETE' marker from dual;
exit
