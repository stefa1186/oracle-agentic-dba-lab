#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 06): sourced by the post 06 scripts, not executed.
#
# Reuses post 04's helpers (and through them posts 01-03: settings, lab user,
# db_sqlplus as SYSDBA in the container) and adds the post 06 settings and
# helpers. The agent's account is not touched in this post: it reads a report,
# it doesn't query the database.
# =============================================================================

# Folder of the post 06 scripts.
POST06_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 04 helpers (and posts 01-03 through them).
# shellcheck source=../post-04-auditing-the-agent/lib.sh
source "${POST06_DIR}/../post-04-auditing-the-agent/lib.sh"

# Where this post keeps its evidence.
POST06_OUT="${OUTPUT_DIR}/post-06-awr"
# The two snapshot IDs bracketing the workload (written by 02_generate_load.sh).
SNAPSHOTS_FILE="${POST06_OUT}/snapshots.txt"
# One log per workload session of the latest load (written by 02_generate_load.sh).
SESSIONS_DIR="${POST06_OUT}/sessions"
# The AWR report the agent reads (written by 03_awr_report.sh).
AWR_REPORT="${POST06_OUT}/awr_report.txt"
# The same report with ADDM's sections removed: the harder test (also by 03).
AWR_REPORT_NOADDM="${POST06_OUT}/awr_report_noaddm.txt"
# What AWR measured for the planted problems (written by 03_awr_report.sh).
ANSWER_KEY="${POST06_OUT}/answer_key.txt"

# Load posts 01-04 settings, then post 06 settings.
load_post06_config() {
    # Everything from posts 01-04.
    load_post04_config
    # Post 06 defaults.
    # shellcheck source=env.example
    source "${POST06_DIR}/env.example"
    # Post 06 local overrides, if any.
    if [[ -f "${POST06_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST06_DIR}/.env"
    fi
    # The schema name goes into SQL: a plain upper-case Oracle identifier only.
    [[ "${AWR_SCHEMA}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "AWR_SCHEMA must be an upper-case Oracle identifier."
    # Numbers go into SQL: whole numbers only.
    local v
    for v in AWR_LOAD_SECONDS AWR_LOCK_WAITERS AWR_LOCK_HOLD_SECONDS AWR_LITERAL_SESSIONS; do
        [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "${v} must be a positive whole number."
    done
    # Keep the load short enough for a lab, long enough to matter in AWR.
    (( AWR_LOAD_SECONDS >= 60 && AWR_LOAD_SECONDS <= 1800 )) || die "AWR_LOAD_SECONDS must be between 60 and 1800."
    # The lock must be released several times per run, or the waiters starve.
    (( AWR_LOCK_HOLD_SECONDS * 4 <= AWR_LOAD_SECONDS )) || die "AWR_LOCK_HOLD_SECONDS is too long for AWR_LOAD_SECONDS."
    # Sessions running at once: the lock holder, the waiters, the literal-SQL sessions.
    SESSIONS_NEEDED=$(( 1 + AWR_LOCK_WAITERS + AWR_LITERAL_SESSIONS ))
    # The evidence folder exists from here on.
    mkdir -p "${POST06_OUT}"
}

# The substitution variables every post 06 SQL file may use, one "define" per line.
post06_defines() {
    echo "define awr_schema   = ${AWR_SCHEMA}"
    echo "define load_seconds = ${AWR_LOAD_SECONDS}"
    echo "define lock_waiters = ${AWR_LOCK_WAITERS}"
    echo "define lock_hold    = ${AWR_LOCK_HOLD_SECONDS}"
    echo "define literal_sess = ${AWR_LITERAL_SESSIONS}"
}

# Run a SQL file from this folder as SYSDBA in the container. The file uses
# SQL*Plus substitution variables (&name); their values are defined first.
# The file is streamed through stdin, so the shell never touches the "$" in
# names like V$DATABASE, and nothing (a password included) appears on a
# command line.
# Usage: run_post06_sql <file.sql> [extra "define name = value" lines...]
run_post06_sql() {
    local file="${POST06_DIR}/$1"
    shift
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    {
        post06_defines
        # Any extra definitions from the caller (snapshot IDs, the password).
        local extra
        for extra in "$@"; do echo "${extra}"; done
        cat "${file}"
    } | db_sqlplus
}

# Run a workload session file from this folder in SQL*Plus WITHOUT logging in
# (/nolog): the file connects as the application user itself. Same defines,
# same stdin rule as run_post06_sql.
# Usage: run_post06_session <file.sql> [extra "define name = value" lines...]
run_post06_session() {
    local file="${POST06_DIR}/$1"
    shift
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    {
        post06_defines
        local extra
        for extra in "$@"; do echo "${extra}"; done
        cat "${file}"
    } | podman exec -i "${DB_CONTAINER}" sqlplus -s -L /nolog
}

# Kill every session of the workload user in FREEPDB1 (an interrupted or
# overrunning load). Prints how many were killed. Safe when there are none.
kill_workload_sessions() {
    db_sqlplus <<SQL | sed -n 's/^KILLED=//p'
set heading off feedback off pagesize 0
alter session set container = FREEPDB1;
-- DBMS_OUTPUT belongs to the container session: enable it after the switch.
set serveroutput on
declare
    l_n pls_integer := 0;
begin
    for s in (select sid, serial# from v\$session where username = '${AWR_SCHEMA}') loop
        execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
        l_n := l_n + 1;
    end loop;
    dbms_output.put_line('KILLED=' || l_n);
end;
/
exit
SQL
}

# Read the begin and end snapshot IDs saved by 02_generate_load.sh.
# Prints "BEGIN_ID END_ID".
read_snapshots() {
    [[ -f "${SNAPSHOTS_FILE}" ]] || die "no snapshots yet: run ./02_generate_load.sh first."
    local begin_id end_id
    # The file holds two lines: BEGIN_SNAP=<n> and END_SNAP=<n>.
    begin_id="$(sed -n 's/^BEGIN_SNAP=\([0-9]\+\)$/\1/p' "${SNAPSHOTS_FILE}")"
    end_id="$(sed -n 's/^END_SNAP=\([0-9]\+\)$/\1/p' "${SNAPSHOTS_FILE}")"
    [[ -n "${begin_id}" && -n "${end_id}" ]] || die "${SNAPSHOTS_FILE} is incomplete: rerun ./02_generate_load.sh."
    echo "${begin_id} ${end_id}"
}

# Resolve a harness run folder of this post (the one holding events.jsonl).
# With an argument: that folder. Without: the most recent post 06 run.
resolve_post06_run_dir() {
    local dir="${1:-}"
    if [[ -z "${dir}" ]]; then
        # Run folders are <timestamp>/<model>/run-N; the timestamp sorts in time order.
        dir="$(ls -1d "${POST06_OUT}"/*/*/run-* 2>/dev/null | sort | tail -1 || true)"
        [[ -n "${dir}" ]] || die "no agent run found under ${POST06_OUT}. Run the agent first (see README)."
    fi
    [[ -f "${dir}/events.jsonl" ]] || die "${dir} has no events.jsonl: not a harness run folder."
    # Print the absolute path.
    (cd "${dir}" && pwd)
}
