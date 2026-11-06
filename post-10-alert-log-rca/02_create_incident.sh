#!/usr/bin/env bash
# =============================================================================
# 02_create_incident.sh
#
# Causes the incident the agent investigates:
#   1. setup_shop.sql: the application user SHOP_APP (with a password that
#      exists only for this run) and its tables STOCK and ORDERS
#   2. two sessions take the same two rows in opposite order: a deadlock.
#      Oracle raises ORA-00060 in one of them (written to the alert log,
#      with a trace file). The application catches it and leaves its
#      transaction open: the real incident
#   3. PILEUP_SESSIONS shop users then queue behind it ("the shop is frozen")
#   4. SHOP_APP is locked (sessions already connected keep running), and the
#      state is checked: every session but one waiting, and an ORA-00060 in
#      the alert log since the start
# The sessions run in the background, detached from this script, for
# INCIDENT_MINUTES (or until ./99_cleanup.sh ends them). One log per session
# goes to sessions/; the start time goes to incident.txt.
#
# Run as the lab user, after ./01_prepare_agent.sh. Rerunning ends the
# previous incident first and starts a fresh one, identical.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-10 settings.
load_post10_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# A password for this run only: "Sh" + 30 random hex characters (letters and
# digits only, so it needs no escaping anywhere). Never written to disk.
shop_pwd="Sh$(od -An -N15 -tx1 /dev/urandom | tr -d ' \n')"

step "1/4 The shop application"
# A previous incident's sessions end first, or the user can't be dropped.
if ! output="$(run_post10_sql stop_incident.sql)"; then
    echo "${output}" >&2
    die "ending the previous incident failed."
fi
grep -q INCIDENT_STOPPED <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
# ... and its client processes (a held session would otherwise sit out its pause).
stop_incident_clients
if ! output="$(run_post10_sql setup_shop.sql "define shop_pwd = ${shop_pwd}")"; then
    # Show what SQL*Plus said (verify is off: the password isn't in it), then stop.
    echo "${output}" >&2
    die "creating the shop application failed."
fi
grep -q SHOP_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "${SHOP_SCHEMA} created: STOCK (50 items), ORDERS (1,000 orders)."

# The incident's start, UTC: the alert log check below counts from here, and
# 04_dba_investigation.sh reads it.
start_utc="$(date -u '+%Y-%m-%d %H:%M:%S')"
printf 'INCIDENT_START_UTC=%s\n' "${start_utc}" > "${INCIDENT_FILE}"

# A fresh folder for this incident's session logs.
rm -rf "${SESSIONS_DIR}"
mkdir -p "${SESSIONS_DIR}"

# Start one session in the background, detached (setsid + nohup): it must
# outlive this script, for the whole investigation. The password goes to
# incident_session.sh through stdin, never on a command line. Its process
# group ID goes to <name>.pid, so the incident can be stopped completely.
# Usage: start_session <name> <file.sql> [<then_file.sql>]
start_session() {
    printf '%s\n' "${shop_pwd}" | setsid nohup "${POST10_DIR}/incident_session.sh" "${@:2}" \
        > "${SESSIONS_DIR}/$1.log" 2>&1 &
    # $! is the setsid process, which becomes the group leader.
    echo "$!" > "${SESSIONS_DIR}/$1.pid"
    info "started $1"
}

step "2/4 The deadlock"
# Order entry is HELD: after its block it stays connected and idle, with its
# transaction open, until the incident time is over (then the "end" file).
start_session order_entry session_order_entry.sql session_order_entry_end.sql
# One second later, so order entry waits first and is the one Oracle picks.
sleep 1
start_session invoicing session_invoicing.sql
# Locks at 0 and 1 s, waits from 3 and 4 s, detection about 3 s after the first wait.
info "waiting 10 s for Oracle's deadlock detection..."
sleep 10

step "3/4 ${PILEUP_SESSIONS} shop users queue behind it"
for i in $(seq 1 "${PILEUP_SESSIONS}"); do
    start_session "user_${i}" session_user.sql
done
# Time to connect and reach the lock.
sleep 5

step "4/4 Lock the account, check the incident"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set heading off feedback off pagesize 0 linesize 200
alter session set container = FREEPDB1;
-- New logins are refused from here on; the connected sessions keep running.
alter user ${SHOP_SCHEMA} account lock;
-- Sessions of the application, and how many of them are waiting behind another.
select 'SESSIONS=' || count(*) || ' BLOCKED=' || count(blocking_session)
from   v\$session where username = '${SHOP_SCHEMA}';
-- ORA-00060 entries in the alert log since the incident started.
select 'ALERT_ORA60=' || count(*)
from   v\$diag_alert_ext
where  message_text like '%ORA-00060%'
and    sys_extract_utc(originating_timestamp) >= to_timestamp('${start_utc}', 'YYYY-MM-DD HH24:MI:SS');
exit
SQL
)"; then
    echo "${output}" >&2
    die "checking the incident failed."
fi
sessions_line="$(grep '^SESSIONS=' <<< "${output}")"
alert_line="$(grep '^ALERT_ORA60=' <<< "${output}")"
info "${sessions_line}  ${alert_line}"
# Expected: order entry, invoicing and every user connected; all but order entry blocked.
expected_sessions=$(( 2 + PILEUP_SESSIONS ))
expected_blocked=$(( 1 + PILEUP_SESSIONS ))
if [[ "${sessions_line}" != "SESSIONS=${expected_sessions} BLOCKED=${expected_blocked}" || "${alert_line}" == "ALERT_ORA60=0" ]]; then
    warn "not the expected incident (SESSIONS=${expected_sessions} BLOCKED=${expected_blocked}, ALERT_ORA60 >= 1). Session logs:"
    tail -n 5 "${SESSIONS_DIR}"/*.log >&2
    die "the incident did not start as planned; rerun ./02_create_incident.sh, or ./99_cleanup.sh."
fi

step "Done"
info "The incident runs for ${INCIDENT_MINUTES} minutes from ${start_utc} UTC, or until ./99_cleanup.sh."
info "Session logs: ${SESSIONS_DIR}/"
info "Next: ./03_run_agent.sh"
