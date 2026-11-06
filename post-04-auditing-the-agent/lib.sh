#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 04): sourced by the post 04 scripts, not executed.
#
# Reuses post 03's helpers (and through them posts 01-02: settings, lab user,
# db_sqlplus, the replay tool) and adds the post 04 settings and helpers.
# =============================================================================

# Folder of the post 04 scripts.
POST04_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 03 helpers (and posts 01-02 through them).
# shellcheck source=../post-03-least-privilege/lib.sh
source "${POST04_DIR}/../post-03-least-privilege/lib.sh"

# Where the agent harness writes its run folders.
OUTPUT_DIR="$(cd "${POST04_DIR}/.." && pwd)/output"

# Load posts 01-03 settings, then post 04 settings.
load_post04_config() {
    # Everything from posts 01-03.
    load_post03_config
    # Post 04 defaults.
    # shellcheck source=env.example
    source "${POST04_DIR}/env.example"
    # Post 04 local overrides, if any.
    if [[ -f "${POST04_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST04_DIR}/.env"
    fi
    # Policy name: a plain Oracle identifier, safe inside SQL.
    [[ "${AUDIT_POLICY}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "AUDIT_POLICY must be an upper-case Oracle identifier."
    # Margin: a whole number of seconds.
    [[ "${AUDIT_WINDOW_MARGIN}" =~ ^[0-9]+$ ]] || die "AUDIT_WINDOW_MARGIN must be a whole number of seconds."
}

# Resolve a harness run folder (the one holding events.jsonl).
# With an argument: that folder. Without: the most recent post 04 run.
resolve_run_dir() {
    local dir="${1:-}"
    if [[ -z "${dir}" ]]; then
        # Newest events.jsonl under this post's output folder (names start with a sortable timestamp).
        dir="$(ls -1d "${OUTPUT_DIR}"/post-04-auditing-the-agent/*/*/run-* 2>/dev/null | sort | tail -1 || true)"
        [[ -n "${dir}" ]] || die "no agent run found under ${OUTPUT_DIR}/post-04-auditing-the-agent. Run the agent first (see README)."
    fi
    [[ -f "${dir}/events.jsonl" ]] || die "${dir} has no events.jsonl: not a harness run folder."
    # Print the absolute path.
    (cd "${dir}" && pwd)
}

# Write the agent's audit records between two UTC timestamps
# ("YYYY-MM-DD HH:MM:SS.ffffff"), widened by AUDIT_WINDOW_MARGIN, to stdout:
# one JSON object per line. The database builds the JSON (JSON_OBJECT), so
# quotes, newlines and special characters in the audited SQL are escaped
# correctly; plain CSV from SQL*Plus is not reliable for SQL text.
fetch_audit_jsonl() {
    local start="$1" end="$2" ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$'
    # Only well-formed timestamps go into the SQL.
    [[ "${start}" =~ ${ts_re} && "${end}" =~ ${ts_re} ]] || die "invalid time window: '${start}' .. '${end}'"
    db_sqlplus <<SQL
set feedback off heading off pagesize 0 linesize 32767 trimspool on
-- SQL*Plus replaces runs of spaces with TAB characters by default (SET TAB ON),
-- even inside the JSON text: switch that off, so the output is exactly what
-- the database produced.
set tab off
alter session set container = FREEPDB1;
-- Write any audit records still in memory to the trail first (harmless if there are none).
-- Through EXECUTE IMMEDIATE: the procedure no longer exists in 26ai (records
-- are written at once), and a direct call fails at COMPILE time (PLS-00302),
-- which no exception handler can catch: it printed an error into every export.
begin execute immediate 'begin dbms_audit_mgmt.flush_unified_audit_trail; end;'; exception when others then null; end;
/
-- One line per record. SQL text is cut at 1500 characters so the whole
-- object always fits in VARCHAR2(4000), even after JSON escaping.
select json_object(
         'TS'                   value to_char(event_timestamp_utc, 'YYYY-MM-DD HH24:MI:SS.FF6'),
         'SESSIONID'            value to_char(sessionid),
         'ACTION_NAME'          value action_name,
         'RETURN_CODE'          value to_char(return_code),
         'CLIENT_PROGRAM_NAME'  value client_program_name,
         'APPLICATION_CONTEXTS' value application_contexts,
         'POLICIES'             value unified_audit_policies,
         'SQL_TEXT'             value dbms_lob.substr(sql_text, 1500, 1)
         returning varchar2(4000))
from   unified_audit_trail
where  dbusername = '${AGENT_DB_USER}'
and    event_timestamp_utc between to_timestamp('${start}', 'YYYY-MM-DD HH24:MI:SS.FF6') - numtodsinterval(${AUDIT_WINDOW_MARGIN}, 'SECOND')
                               and to_timestamp('${end}',   'YYYY-MM-DD HH24:MI:SS.FF6') + numtodsinterval(${AUDIT_WINDOW_MARGIN}, 'SECOND')
order  by event_timestamp_utc, entry_id;
exit
SQL
}

# Print the UTC start and end of a run as "YYYY-MM-DD HH:MM:SS.ffffff YYYY-MM-DD HH:MM:SS.ffffff",
# taken from the first and last event in its events.jsonl.
run_window_utc() {
    python3 - "$1/events.jsonl" <<'PY'
# Read the first and last timestamps of the run (ISO 8601, UTC, from the harness).
import datetime, json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
def fmt(ts):
    # Convert to UTC and print in the format Oracle's TO_TIMESTAMP reads below.
    return datetime.datetime.fromisoformat(ts).astimezone(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")
print(fmt(events[0]["ts"]), fmt(events[-1]["ts"]))
PY
}
