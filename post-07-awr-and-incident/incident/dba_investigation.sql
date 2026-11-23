-- =============================================================================
-- dba_investigation.sql  (run by 04_dba_investigation.sh as SYSDBA)
--
-- My own first 20 minutes on the same incident, to judge the agent's
-- hypothesis against. Read-only. &start_utc is the incident's start (UTC).
-- =============================================================================

whenever sqlerror exit failure
set verify off feedback off pagesize 100 linesize 220 trimspool on tab off
alter session set container = FREEPDB1;
column ts         format a19
column message    format a150
column chain      format a110
column event      format a32
column samples    format 9999
column line       format a150

prompt
prompt === 1. The alert log since the incident started
select to_char(originating_timestamp at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') ts,
       substr(replace(message_text, chr(10), ' '), 1, 150) message
from   v$diag_alert_ext
where  sys_extract_utc(originating_timestamp) >= to_timestamp('&start_utc', 'YYYY-MM-DD HH24:MI:SS')
order  by originating_timestamp;

prompt
prompt === 2. The deadlock graph, from the trace file the alert log names
-- The trace file of the ORA-00060 entry: the last word of the message, its file name only.
column trace_file new_value trace_file noprint
select regexp_substr(message_text, '[^/ ]+\.trc') trace_file
from   v$diag_alert_ext
where  message_text like '%ORA-00060%'
and    sys_extract_utc(originating_timestamp) >= to_timestamp('&start_utc', 'YYYY-MM-DD HH24:MI:SS')
order  by originating_timestamp desc
fetch  first 1 row only;
prompt Trace file: &trace_file
-- The trace as written, from "DEADLOCK DETECTED" on: the verdict, the graph
-- with its header, and each session's current SQL (50 lines, blank ones skipped).
select substr(rtrim(c.payload, chr(10)), 1, 150) line
from   v$diag_trace_file_contents c
where  c.trace_filename = '&trace_file'
and    c.line_number between (select min(line_number) from v$diag_trace_file_contents
                              where trace_filename = '&trace_file' and payload like '%DEADLOCK DETECTED%')
                         and (select min(line_number) from v$diag_trace_file_contents
                              where trace_filename = '&trace_file' and payload like '%DEADLOCK DETECTED%') + 50
and    trim(rtrim(c.payload, chr(10))) is not null
order  by c.line_number;

prompt
prompt === 3. Who blocks whom, now
select s.sid || ' ' || s.module || ' / ' || s.action
       || case when s.blocking_session is not null
               then '  waits on "' || s.event || '" behind SID ' || s.blocking_session
               else '  (' || s.state || ', ' || s.event || ', idle in transaction for ' || s.last_call_et || ' s)' end chain
from   v$session s
where  s.username = '&shop_schema'
order  by s.blocking_session nulls first, s.sid;

prompt
prompt === 4. Session history (ASH) since the incident started: the shop's sessions
-- ASH leaves EVENT empty for a sample on CPU: name it, as the ASH report does.
select nvl(event, 'ON CPU') event, count(*) samples
from   v$active_session_history
where  sample_time >= to_timestamp('&start_utc', 'YYYY-MM-DD HH24:MI:SS')
and    user_id = (select user_id from dba_users where username = '&shop_schema')
group  by nvl(event, 'ON CPU')
order  by samples desc;
exit
