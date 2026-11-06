#!/usr/bin/env bash
# =============================================================================
# 04_sql_firewall.sh
#
# Oracle SQL Firewall for the agent's account: the database itself rejects
# any SQL that isn't on an allow-list, with ORA-47605, whatever the prompt
# says and whatever the model decides.
#
#   ./04_sql_firewall.sh capture   learn the allow-list from approved_queries.sql,
#                                  then ENFORCE it (block unknown SQL)
#   ./04_sql_firewall.sh observe   keep the allow-list, but only LOG violations
#   ./04_sql_firewall.sh enforce   block violations again
#   ./04_sql_firewall.sh off       stop applying the allow-list (kept for later)
#   ./04_sql_firewall.sh status    show the state, the allowed SQL, recent violations
#   ./04_sql_firewall.sh remove    drop the allow-list, capture and logs
#
# Deterministic: "capture" always starts from scratch (old allow-list and
# capture dropped) and learns ONLY from approved_queries.sql, replayed through
# SQLcl MCP without a model. The same file always gives the same allow-list.
#
# Oracle analogy: a network firewall rule set, but for SQL statements and
# enforced inside the database, where neither the agent nor the prompt can
# reach it.
#
# Run as the lab user. SQL runs as SYSDBA inside the container.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-03 settings.
load_post03_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Run firewall SQL as SYSDBA in FREEPDB1; stop on the first error.
fw_sql() {
    db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0 linesize 200 serveroutput on
alter session set container = FREEPDB1;
$1
exit
SQL
}

# PL/SQL that turns the allow-list on, blocking (TRUE) or logging only (FALSE).
# It is first disabled (ignoring "not enabled"), so the call works in any state.
apply_allow_list() {
    fw_sql "
begin
    begin dbms_sql_firewall.disable_allow_list(username => '${AGENT_DB_USER}'); exception when others then null; end;
    dbms_sql_firewall.enable_allow_list(
        username => '${AGENT_DB_USER}',
        enforce  => dbms_sql_firewall.enforce_sql,   -- check the SQL text (not IP/program)
        block    => $1);                             -- TRUE: reject; FALSE: log only
end;
/" >/dev/null
}

# Show the state, the allowed SQL and the latest violations.
show_status() {
    db_sqlplus <<SQL
-- tab off: spaces instead of tabs, so the report pastes into a post unchanged.
set feedback off pagesize 100 linesize 200 tab off
column status      format a10
column enforce     format a14
column block       format a6
column sql_text    format a110
column cause       format a18
column occurred_at format a28
alter session set container = FREEPDB1;
-- Write any in-memory log entries to disk first, so the report is current.
exec dbms_sql_firewall.flush_logs
prompt
prompt === Firewall
select status from dba_sql_firewall_status;
prompt
prompt === Allow-list for ${AGENT_DB_USER}
select status, enforce, block from dba_sql_firewall_allow_lists where username = '${AGENT_DB_USER}';
prompt
prompt === Allowed SQL
select sql_text from dba_sql_firewall_allowed_sql where username = '${AGENT_DB_USER}' order by sql_text;
prompt
prompt === Last 10 violations
select * from (
    select occurred_at, cause, firewall_action, sql_text
    from   dba_sql_firewall_violations
    where  username = '${AGENT_DB_USER}'
    order  by occurred_at desc)
where rownum <= 10;
exit
SQL
}

# Which mode?
mode="${1:-}"
case "${mode}" in
    capture)
        step "1/5 Enable SQL Firewall in FREEPDB1"
        # Enable only if not enabled yet (enabling twice is an error).
        fw_sql "
begin
    for s in (select status from dba_sql_firewall_status where status <> 'ENABLED') loop
        dbms_sql_firewall.enable;
    end loop;
end;
/" >/dev/null
        info "Enabled."

        step "2/5 Start a fresh capture for ${AGENT_DB_USER}"
        # Drop any previous allow-list and capture, so only this run counts.
        fw_sql "
begin
    begin dbms_sql_firewall.disable_allow_list(username => '${AGENT_DB_USER}'); exception when others then null; end;
    begin dbms_sql_firewall.drop_allow_list(username => '${AGENT_DB_USER}');    exception when others then null; end;
    begin dbms_sql_firewall.stop_capture(username => '${AGENT_DB_USER}');       exception when others then null; end;
    begin dbms_sql_firewall.drop_capture(username => '${AGENT_DB_USER}');       exception when others then null; end;
    dbms_sql_firewall.create_capture(
        username       => '${AGENT_DB_USER}',
        top_level_only => true,    -- record the statements sent by the client, not PL/SQL internals
        start_capture  => true);
end;
/" >/dev/null
        info "Capturing."

        step "3/5 Replay approved_queries.sql through SQLcl MCP (no model)"
        # The replay connects exactly like the agent, so SQLcl's own connect-time
        # statements are captured too; without them, the agent could not even connect.
        replay "${POST03_DIR}/approved_queries.sql"

        step "4/5 Stop the capture and generate the allow-list"
        fw_sql "
begin
    dbms_sql_firewall.stop_capture(username => '${AGENT_DB_USER}');
    dbms_sql_firewall.generate_allow_list(username => '${AGENT_DB_USER}');
end;
/" >/dev/null
        info "Allow-list generated."

        step "5/5 Enforce: block any other SQL"
        apply_allow_list TRUE
        info "Enforcing. Unknown SQL from ${AGENT_DB_USER} now fails with ORA-47605."
        show_status
        ;;
    observe)
        step "Allow-list in OBSERVE mode (violations logged, not blocked)"
        apply_allow_list FALSE
        show_status
        ;;
    enforce)
        step "Allow-list ENFORCING (violations blocked)"
        apply_allow_list TRUE
        show_status
        ;;
    off)
        step "Allow-list OFF (kept; './04_sql_firewall.sh enforce' turns it back on)"
        fw_sql "begin dbms_sql_firewall.disable_allow_list(username => '${AGENT_DB_USER}'); exception when others then null; end;
/" >/dev/null
        show_status
        ;;
    status)
        show_status
        ;;
    remove)
        step "Removing the allow-list, capture and logs for ${AGENT_DB_USER}"
        fw_sql "
begin
    begin dbms_sql_firewall.disable_allow_list(username => '${AGENT_DB_USER}'); exception when others then null; end;
    begin dbms_sql_firewall.drop_allow_list(username => '${AGENT_DB_USER}');    exception when others then null; end;
    begin dbms_sql_firewall.stop_capture(username => '${AGENT_DB_USER}');       exception when others then null; end;
    begin dbms_sql_firewall.drop_capture(username => '${AGENT_DB_USER}');       exception when others then null; end;
    -- purge_log(username, purge before timestamp (null = everything), log type), positional as documented.
    begin dbms_sql_firewall.purge_log('${AGENT_DB_USER}', null, dbms_sql_firewall.all_logs); exception when others then null; end;
end;
/" >/dev/null
        info "Removed. (SQL Firewall itself stays enabled; it has no effect without an allow-list.)"
        ;;
    *)
        die "usage: $0 capture|observe|enforce|off|status|remove"
        ;;
esac
