#!/usr/bin/env bash
# =============================================================================
# 02_generate_load.sh
#
# Runs the workload with the two planted problems between two AWR snapshots:
#   1. setup_load.sql: the application user AWR_LOAD (with a password that
#      exists only for this run) and its tables
#   2. BEGIN snapshot, then all workload sessions started side by side, each
#      an ordinary SQL*Plus session logged in as AWR_LOAD:
#        session_lock_holder.sql   x 1
#        session_lock_waiter.sql   x AWR_LOCK_WAITERS
#        session_literal_sql.sql   x AWR_LITERAL_SESSIONS
#   3. wait for all of them (AWR_LOAD_SECONDS, plus a margin), then the END
#      snapshot, and AWR_LOAD is locked again
# Saves the snapshot IDs (snapshots.txt) and one log per session (sessions/).
#
# The password: random, generated here, passed to SQL*Plus through stdin only,
# never written to disk, useless once the account is locked at the end.
#
# Run as the lab user. SQL runs as SYSDBA inside the container (no password).
# Deterministic: a previous run's sessions and schema are removed first. The
# timings vary from run to run; the two problems don't.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-06 settings.
load_post06_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# A password for this run only: "Aw" + 30 random hex characters (letters and
# digits only, so it needs no escaping anywhere).
awr_pwd="Aw$(od -An -N15 -tx1 /dev/urandom | tr -d ' \n')"

# However this script ends, no workload session may outlive it, and the
# account must end up locked.
cleanup_on_exit() {
    # Stop the background SQL*Plus clients, if any are left.
    local pid
    for pid in "${pids[@]:-}"; do
        [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
    done
    # Kill the database sessions themselves (killing a client may not end them).
    local killed
    killed="$(kill_workload_sessions || true)"
    [[ -n "${killed}" && "${killed}" != "0" ]] && info "killed ${killed} leftover workload session(s)."
    # Lock the account: the password of this run is useless from here on.
    db_sqlplus <<SQL >/dev/null 2>&1 || true
alter session set container = FREEPDB1;
alter user ${AWR_SCHEMA} account lock;
exit
SQL
}
pids=()
trap cleanup_on_exit EXIT

step "1/4 The application user and its tables"
# A previous load's jobs and sessions end first, or its user can't be dropped.
if ! output="$(run_post06_sql stop_workload.sql)"; then
    echo "${output}" >&2
    die "stopping the previous workload failed."
fi
grep -q WORKLOAD_STOPPED <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
if ! output="$(run_post06_sql setup_load.sql "define awr_pwd = ${awr_pwd}")"; then
    # Show what SQL*Plus said (verify is off: the password isn't in it), then stop.
    echo "${output}" >&2
    die "workload setup failed."
fi
grep -q SCHEMA_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "${AWR_SCHEMA} created: ACCOUNTS (1,000 rows), ORDERS (100,000 rows)."

step "2/4 BEGIN snapshot, then ${SESSIONS_NEEDED} workload sessions"
output="$(run_post06_sql snapshot.sql "define snap_label = BEGIN_SNAP")"
begin_snap="$(sed -n 's/^BEGIN_SNAP=\([0-9]\+\)$/\1/p' <<< "${output}")"
[[ -n "${begin_snap}" ]] || { echo "${output}" >&2; die "no BEGIN snapshot ID in the output."; }
info "BEGIN snapshot: ${begin_snap}"
# Record the begin snapshot now: if the load is interrupted, the file says so.
printf 'BEGIN_SNAP=%s\n' "${begin_snap}" > "${SNAPSHOTS_FILE}"

# A fresh folder for this load's session logs.
rm -rf "${SESSIONS_DIR}"
mkdir -p "${SESSIONS_DIR}"
# Start one session in the background, its output in its own log.
# Usage: start_session <name> <file.sql> <session number>
start_session() {
    run_post06_session "$2" "define awr_pwd = ${awr_pwd}" "define session_no = $3" \
        > "${SESSIONS_DIR}/$1.log" 2>&1 &
    pids+=("$!")
    info "started $1"
}
start_session lock_holder session_lock_holder.sql 0
for i in $(seq 1 "${AWR_LOCK_WAITERS}"); do
    start_session "lock_waiter_${i}" session_lock_waiter.sql "${i}"
done
for i in $(seq 1 "${AWR_LITERAL_SESSIONS}"); do
    start_session "literal_sql_${i}" session_literal_sql.sql "${i}"
done

step "3/4 Waiting for the workload to finish"
# The longest a session can run: the load time, one more lock hold, and a margin.
deadline=$(( SECONDS + AWR_LOAD_SECONDS + AWR_LOCK_HOLD_SECONDS + 60 ))
while :; do
    # How many of the background sessions are still running.
    running=0
    for pid in "${pids[@]}"; do
        kill -0 "${pid}" 2>/dev/null && running=$((running + 1))
    done
    (( running == 0 )) && break
    (( SECONDS < deadline )) || die "${running} session(s) still running after the deadline (they are killed on exit)."
    info "${running} session(s) running, $(( deadline - SECONDS ))s to the deadline..."
    # Poll every 15 seconds: the load takes minutes, not seconds.
    sleep 15
done
# All background clients have ended: nothing left for the exit trap to stop.
pids=()

# Every session must have reached its end marker; anything else means the load
# wasn't what was planned.
failed=0
for log in "${SESSIONS_DIR}"/*.log; do
    name="$(basename "${log}" .log)"
    if grep -q SESSION_DONE "${log}"; then
        # The session's own count of what it did (lock periods, updates, executions).
        info "${name}: $(grep -E 'lock periods|updates|executions' "${log}" | head -1 | sed 's/^ *//')"
    else
        warn "${name} did not finish: $(grep -m1 -E 'ORA-|SP2-' "${log}" || echo 'no error in its log')"
        failed=1
    fi
done
(( failed == 0 )) || die "a workload session failed: see ${SESSIONS_DIR}/."

step "4/4 END snapshot"
output="$(run_post06_sql snapshot.sql "define snap_label = END_SNAP")"
end_snap="$(sed -n 's/^END_SNAP=\([0-9]\+\)$/\1/p' <<< "${output}")"
[[ -n "${end_snap}" ]] || { echo "${output}" >&2; die "no END snapshot ID in the output."; }
info "END snapshot: ${end_snap}"
# Both IDs, for 03_awr_report.sh.
printf 'BEGIN_SNAP=%s\nEND_SNAP=%s\n' "${begin_snap}" "${end_snap}" > "${SNAPSHOTS_FILE}"

step "Done"
info "Saved: ${SNAPSHOTS_FILE} and ${SESSIONS_DIR}/"
info "${AWR_SCHEMA} is locked again (on exit)."
info "Next: ./03_awr_report.sh"
