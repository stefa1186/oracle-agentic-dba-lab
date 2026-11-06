#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 05): sourced by the post 05 scripts, not executed.
#
# Reuses post 04's helpers (and through them posts 01-03: settings, lab user,
# db_sqlplus, the replay tool, the audit export) and adds the post 05
# settings and helpers.
# =============================================================================

# Folder of the post 05 scripts.
POST05_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 04 helpers (and posts 01-03 through them).
# shellcheck source=../post-04-auditing-the-agent/lib.sh
source "${POST05_DIR}/../post-04-auditing-the-agent/lib.sh"

# Where this post keeps its evidence: the answer key, the checklist output
# and (in per-run subfolders, written by the harness) the agent runs.
POST05_OUT="${OUTPUT_DIR}/post-05-health-check"
# The answer key written by 02_seed_known_problems.sh.
ANSWER_KEY="${POST05_OUT}/answer_key.txt"
# The DBA checklist output written by 03_dba_checklist.sh.
CHECKLIST_OUT="${POST05_OUT}/checklist.txt"

# Load posts 01-04 settings, then post 05 settings.
load_post05_config() {
    # Everything from posts 01-04.
    load_post04_config
    # Post 05 defaults.
    # shellcheck source=env.example
    source "${POST05_DIR}/env.example"
    # Post 05 local overrides, if any.
    if [[ -f "${POST05_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST05_DIR}/.env"
    fi
    # Names go into SQL: plain upper-case Oracle identifiers only.
    local v
    for v in HC_SCHEMA HC_LEGACY_USER HC_TABLESPACE; do
        [[ "${!v}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "${v} must be an upper-case Oracle identifier."
    done
    # Numbers go into SQL: whole numbers only.
    for v in HC_TS_SIZE_MB HC_TS_TARGET_PCT HC_TS_WARN_PCT HC_FRA_WARN_PCT HC_BACKUP_MAX_AGE_DAYS; do
        [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "${v} must be a positive whole number."
    done
    # A percentage above 99 could never be reached in 1 MB steps, and would loop forever.
    (( HC_TS_TARGET_PCT <= 99 && HC_TS_WARN_PCT <= 99 && HC_FRA_WARN_PCT <= 99 )) || die "percentages must be 99 or less."
    # The seed must fill the tablespace past the checklist threshold, or the finding never appears.
    (( HC_TS_TARGET_PCT >= HC_TS_WARN_PCT )) || die "HC_TS_TARGET_PCT must be >= HC_TS_WARN_PCT."
    # The evidence folder exists from here on.
    mkdir -p "${POST05_OUT}"
}

# Run a SQL file from this folder as SYSDBA in the container. The file uses
# SQL*Plus substitution variables (&name); their values are defined first,
# from the validated settings above. The file is streamed through stdin, so it
# never has to exist inside the container, and the shell never touches the "$"
# in names like V$DATABASE.
# Usage: run_post05_sql <file.sql>
run_post05_sql() {
    local file="${POST05_DIR}/$1"
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    {
        # Values for the substitution variables used in the SQL files.
        echo "define hc_schema    = ${HC_SCHEMA}"
        echo "define hc_legacy    = ${HC_LEGACY_USER}"
        echo "define hc_ts        = ${HC_TABLESPACE}"
        echo "define hc_size_mb   = ${HC_TS_SIZE_MB}"
        echo "define hc_target    = ${HC_TS_TARGET_PCT}"
        echo "define ts_warn      = ${HC_TS_WARN_PCT}"
        echo "define fra_warn     = ${HC_FRA_WARN_PCT}"
        echo "define backup_days  = ${HC_BACKUP_MAX_AGE_DAYS}"
        # The SQL itself.
        cat "${file}"
    } | db_sqlplus
}

# Resolve a harness run folder of this post (the one holding events.jsonl).
# With an argument: that folder. Without: the most recent post 05 run.
resolve_post05_run_dir() {
    local dir="${1:-}"
    if [[ -z "${dir}" ]]; then
        # Run folders are <timestamp>/<model>/run-N; the timestamp sorts in time order.
        dir="$(ls -1d "${POST05_OUT}"/*/*/run-* 2>/dev/null | sort | tail -1 || true)"
        [[ -n "${dir}" ]] || die "no agent run found under ${POST05_OUT}. Run the agent first (see README)."
    fi
    [[ -f "${dir}/events.jsonl" ]] || die "${dir} has no events.jsonl: not a harness run folder."
    # Print the absolute path.
    (cd "${dir}" && pwd)
}
