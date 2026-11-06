#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 10): sourced by the post 10 scripts, not executed.
#
# Reuses post 04's helpers (and through them posts 01-03: settings, lab user,
# db_sqlplus, the audit export) and adds the post 10 settings and helpers.
# =============================================================================

# Folder of the post 10 scripts.
POST10_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 04 helpers (and posts 01-03 through them).
# shellcheck source=../post-04-auditing-the-agent/lib.sh
source "${POST10_DIR}/../post-04-auditing-the-agent/lib.sh"

# Where this post keeps its evidence. The harness writes the agent runs here
# too (output/<post folder>/<timestamp>/<model>/run-<n>).
POST10_OUT="${OUTPUT_DIR}/post-10-alert-log-rca"
# One log per incident session (written by 02_create_incident.sh).
SESSIONS_DIR="${POST10_OUT}/sessions"
# When the incident started, UTC (written by 02_create_incident.sh).
INCIDENT_FILE="${POST10_OUT}/incident.txt"

# Load posts 01-04 settings, then post 10 settings.
load_post10_config() {
    # Everything from posts 01-04.
    load_post04_config
    # Post 10 defaults.
    # shellcheck source=env.example
    source "${POST10_DIR}/env.example"
    # Post 10 local overrides, if any.
    if [[ -f "${POST10_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST10_DIR}/.env"
    fi
    # The schema name goes into SQL: a plain upper-case Oracle identifier only.
    [[ "${SHOP_SCHEMA}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "SHOP_SCHEMA must be an upper-case Oracle identifier."
    # Numbers go into SQL: whole numbers in a sensible range.
    [[ "${INCIDENT_MINUTES}" =~ ^[0-9]+$ ]] && (( INCIDENT_MINUTES >= 5 && INCIDENT_MINUTES <= 240 )) \
        || die "INCIDENT_MINUTES must be a whole number from 5 to 240."
    [[ "${PILEUP_SESSIONS}" =~ ^[0-9]+$ ]] && (( PILEUP_SESSIONS >= 1 && PILEUP_SESSIONS <= 10 )) \
        || die "PILEUP_SESSIONS must be a whole number from 1 to 10."
    # The evidence folder exists from here on.
    mkdir -p "${POST10_OUT}"
}

# The substitution variables every post 10 SQL file may use, one "define" per line.
post10_defines() {
    echo "define shop_schema      = ${SHOP_SCHEMA}"
    echo "define incident_seconds = $(( INCIDENT_MINUTES * 60 ))"
}

# Run a SQL file from this folder as SYSDBA in the container. The file is
# streamed through stdin (nothing on a command line, no "$" for the shell).
# Usage: run_post10_sql <file.sql> [extra "define name = value" lines...]
run_post10_sql() {
    local file="${POST10_DIR}/$1"
    shift
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    {
        post10_defines
        local extra
        for extra in "$@"; do echo "${extra}"; done
        cat "${file}"
    } | db_sqlplus
}

# Run an incident session file in SQL*Plus WITHOUT logging in (/nolog): the
# file connects as the application user itself, with the password from the
# "define" lines on stdin.
# Usage: run_post10_session <file.sql> [extra "define name = value" lines...]
run_post10_session() {
    local file="${POST10_DIR}/$1"
    shift
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    {
        post10_defines
        local extra
        for extra in "$@"; do echo "${extra}"; done
        cat "${file}"
    } | podman exec -i "${DB_CONTAINER}" sqlplus -s -L /nolog
}

# Like run_post10_session, but after <file.sql> SQL*Plus gets nothing for
# <seconds>, then <then_file.sql>. Meanwhile the session sits idle ("SQL*Net
# message from client") with whatever transaction it has open: exactly an
# application connection parked in its pool. Nothing in the database shows
# that it is "waiting on purpose".
# Usage: run_post10_session_held <file.sql> <then_file.sql> <seconds> [extra "define name = value" lines...]
run_post10_session_held() {
    local file="${POST10_DIR}/$1"
    local then_file="${POST10_DIR}/$2"
    local seconds="$3"
    shift 3
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    [[ -f "${then_file}" ]] || die "SQL file not found: ${then_file}"
    [[ "${seconds}" =~ ^[0-9]+$ ]] || die "the hold must be a number of seconds: ${seconds}"
    {
        post10_defines
        local extra
        for extra in "$@"; do echo "${extra}"; done
        cat "${file}"
        # The pause: SQL*Plus waits for its next command, the session is idle.
        sleep "${seconds}"
        cat "${then_file}"
    } | podman exec -i "${DB_CONTAINER}" sqlplus -s -L /nolog
}

# Stop the client side of an incident: every process group 02_create_incident.sh
# started (one per session, PID file <name>.pid in SESSIONS_DIR). Killing the
# database sessions (stop_incident.sql) ends the busy clients by themselves,
# but a held client (run_post10_session_held) would sit in its pause until
# the incident time is over. Safe when nothing is running.
stop_incident_clients() {
    local pid_file pid
    for pid_file in "${SESSIONS_DIR}"/*.pid; do
        # No PID files: nothing was started.
        [[ -f "${pid_file}" ]] || continue
        pid="$(cat "${pid_file}")"
        # setsid made each one a process group leader: kill the whole group
        # (the shell, its sleep, podman exec), ignoring groups already gone.
        [[ "${pid}" =~ ^[0-9]+$ ]] && kill -- "-${pid}" 2>/dev/null || true
        rm -f "${pid_file}"
    done
}

# Resolve a harness run folder of this post (the one holding events.jsonl).
# With an argument: that folder. Without: the most recent post 10 run.
resolve_post10_run_dir() {
    local dir="${1:-}"
    if [[ -z "${dir}" ]]; then
        # Run folders are <timestamp>/<model>/run-N; the timestamp sorts in time order.
        dir="$(ls -1d "${POST10_OUT}"/*/*/run-* 2>/dev/null | sort | tail -1 || true)"
        [[ -n "${dir}" ]] || die "no agent run found under ${POST10_OUT}. Run ./03_run_agent.sh first."
    fi
    [[ -f "${dir}/events.jsonl" ]] || die "${dir} has no events.jsonl: not a harness run folder."
    # Print the absolute path.
    (cd "${dir}" && pwd)
}
