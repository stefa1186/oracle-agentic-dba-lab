-- =============================================================================
-- awr_report.sql  (run by 03_awr_report.sh, as SYSDBA, in the root)
--
-- Two outputs between the snapshots &begin_snap and &end_snap:
--   1. the standard AWR text report (DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_TEXT),
--      between the markers #AWR_BEGIN# and #AWR_END#: what the agent reads
--   2. the ANSWER KEY: what AWR measured for the two planted problems, read
--      from the DBA_HIST views directly (not from the report), as KEY lines
-- Read-only. Substitution variables (&begin_snap, &end_snap) come from lib.sh.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Report lines are long and must come out exactly as AWR writes them.
set verify off feedback off heading off pagesize 0 linesize 1500 trimspool on tab off long 100000

-- The database ID and instance number, kept in substitution variables.
column dbid_col new_value l_dbid noprint
column inst_col new_value l_inst noprint
select dbid dbid_col from v$database;
select instance_number inst_col from v$instance;

-- -----------------------------------------------------------------------------
-- 1. The report, exactly as AWR produces it.
-- -----------------------------------------------------------------------------
select '#AWR_BEGIN#' from dual;
select output
from   table(dbms_workload_repository.awr_report_text(&l_dbid, &l_inst, &begin_snap, &end_snap));
select '#AWR_END#' from dual;

-- -----------------------------------------------------------------------------
-- 2. The answer key, from DBA_HIST (instance level, the root's rows).
-- -----------------------------------------------------------------------------
-- Top 5 foreground wait events by time waited (Idle excluded).
select 'KEY | WAIT | ' || rpad(e.event_name, 40) || ' | waits ' || to_char(e.total_waits_fg - b.total_waits_fg)
       || ' | seconds ' || to_char(round((e.time_waited_micro_fg - b.time_waited_micro_fg) / 1e6, 1), 'fm999999990.0')
from   dba_hist_system_event b
join   dba_hist_system_event e
       on  e.event_id = b.event_id and e.dbid = b.dbid and e.instance_number = b.instance_number
       and e.con_dbid = b.con_dbid
where  b.snap_id = &begin_snap and e.snap_id = &end_snap
and    b.dbid = &l_dbid and b.con_dbid = &l_dbid and b.instance_number = &l_inst
and    e.wait_class <> 'Idle'
and    e.time_waited_micro_fg - b.time_waited_micro_fg > 0
order  by e.time_waited_micro_fg - b.time_waited_micro_fg desc
fetch  first 5 rows only;

-- Time model: where DB time went, including parsing.
select 'KEY | TIME | ' || rpad(e.stat_name, 40) || ' | seconds '
       || to_char(round((e.value - b.value) / 1e6, 1), 'fm999999990.0')
from   dba_hist_sys_time_model b
join   dba_hist_sys_time_model e
       on  e.stat_id = b.stat_id and e.dbid = b.dbid and e.instance_number = b.instance_number
       and e.con_dbid = b.con_dbid
where  b.snap_id = &begin_snap and e.snap_id = &end_snap
and    b.dbid = &l_dbid and b.con_dbid = &l_dbid and b.instance_number = &l_inst
and    e.stat_name in ('DB time', 'DB CPU', 'parse time elapsed', 'hard parse elapsed time', 'sql execute elapsed time')
order  by e.stat_name;

-- Counters: how much parsing, executing and committing happened.
select 'KEY | STAT | ' || rpad(e.stat_name, 40) || ' | delta ' || to_char(e.value - b.value)
from   dba_hist_sysstat b
join   dba_hist_sysstat e
       on  e.stat_id = b.stat_id and e.dbid = b.dbid and e.instance_number = b.instance_number
       and e.con_dbid = b.con_dbid
where  b.snap_id = &begin_snap and e.snap_id = &end_snap
and    b.dbid = &l_dbid and b.con_dbid = &l_dbid and b.instance_number = &l_inst
and    e.stat_name in ('parse count (hard)', 'parse count (total)', 'execute count', 'user commits')
order  by e.stat_name;

-- Marker: the shell checks for it.
select 'REPORT_COMPLETE' from dual;
exit
