#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 09): sourced by the post 09 scripts, not executed.
#
# Reuses post 04's helpers (and through them posts 01-03: settings, lab user,
# db_sqlplus, the replay tool, the audit export) and adds the post 09
# settings and helpers.
# =============================================================================

# Folder of the post 09 scripts.
POST09_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 04 helpers (and posts 01-03 through them).
# shellcheck source=../post-04-auditing-the-agent/lib.sh
source "${POST09_DIR}/../post-04-auditing-the-agent/lib.sh"

# Where this post keeps its evidence. The harness writes the agent runs here
# too (output/<post folder>/<timestamp>/<model>/run-<n>).
POST09_OUT="${OUTPUT_DIR}/post-09-breaking-it"

# The three attacks: a letter each, and its prompt file.
#   a  the direct request          (03a_prompt_direct.md)
#   b  injection through data      (03b_prompt_injection.md)
#   c  privilege escalation        (03c_prompt_escalation.md)
ATTACKS="a b c"

# Load posts 01-04 settings, then post 09 settings.
load_post09_config() {
    # Everything from posts 01-04.
    load_post04_config
    # Post 09 defaults.
    # shellcheck source=env.example
    source "${POST09_DIR}/env.example"
    # Post 09 local overrides, if any.
    if [[ -f "${POST09_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST09_DIR}/.env"
    fi
    # Names go into SQL: plain upper-case Oracle identifiers only.
    local v
    for v in INJ_SCHEMA INJ_TABLE; do
        [[ "${!v}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "${v} must be an upper-case Oracle identifier."
    done
    # The sleep goes into SQL too: a whole number from 2 to 60.
    [[ "${BYPASS_SLEEP_SECONDS}" =~ ^[0-9]+$ ]] && (( BYPASS_SLEEP_SECONDS >= 2 && BYPASS_SLEEP_SECONDS <= 60 )) \
        || die "BYPASS_SLEEP_SECONDS must be a whole number from 2 to 60."
    # The evidence folder exists from here on.
    mkdir -p "${POST09_OUT}"
}

# The prompt file of an attack letter (a, b or c).
prompt_of() {
    case "$1" in
        a) echo "${POST09_DIR}/03a_prompt_direct.md" ;;
        b) echo "${POST09_DIR}/03b_prompt_injection.md" ;;
        c) echo "${POST09_DIR}/03c_prompt_escalation.md" ;;
        *) die "unknown attack '$1' (use a, b or c)" ;;
    esac
}

# Run a SQL file from this folder as SYSDBA in the container, with the
# settings defined first as SQL*Plus substitution variables. The file is
# streamed through stdin, so it never has to exist inside the container.
# Usage: run_post09_sql <file.sql>
run_post09_sql() {
    local file="${POST09_DIR}/$1"
    [[ -f "${file}" ]] || die "SQL file not found: ${file}"
    {
        # Values for the substitution variables used in the SQL files.
        echo "define inj_schema = ${INJ_SCHEMA}"
        echo "define inj_table  = ${INJ_TABLE}"
        echo "define agent_user = ${AGENT_DB_USER}"
        echo "define agent_role = ${AGENT_ROLE}"
        # The SQL itself.
        cat "${file}"
    } | db_sqlplus
}

# The newest run of one attack: the newest run folder under POST09_OUT whose
# events.jsonl was started with that attack's prompt file. Prints nothing if
# there is none.
# Usage: latest_run_of <a|b|c>
latest_run_of() {
    local prompt
    prompt="$(basename "$(prompt_of "$1")")"
    # Run folders are <timestamp>/<model>/run-N: sorting the paths sorts them in time order.
    python3 - "${POST09_OUT}" "${prompt}" <<'PY'
# Find the newest run folder whose run_start names the given prompt file.
import json, pathlib, sys
root, prompt = pathlib.Path(sys.argv[1]), sys.argv[2]
found = None
for events in sorted(root.glob("*/*/run-*/events.jsonl")):
    # The first line of events.jsonl is the run_start event.
    with events.open(encoding="utf-8") as f:
        first = json.loads(f.readline() or "{}")
    if first.get("event") == "run_start" and pathlib.Path(first.get("prompt_file", "")).name == prompt:
        found = events.parent
if found:
    print(found)
PY
}

# The current UTC time, in the format fetch_audit_jsonl reads.
utc_now() {
    date -u '+%Y-%m-%d %H:%M:%S.%6N'
}
