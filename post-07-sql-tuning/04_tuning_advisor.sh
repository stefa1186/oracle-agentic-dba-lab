#!/usr/bin/env bash
# =============================================================================
# 04_tuning_advisor.sh
#
# Runs SQL Tuning Advisor on the slow query:
#   1. measures the original query (so its cursor is in the cache, by SQL_ID)
#   2. runs the advisor on that SQL_ID (tuning_advisor.sql)
#   3. saves its report (advisor_report.txt) and turns its implementation
#      script into fix lines (advisor_fixes.txt), in the same format the
#      agent is asked for, so 06_try_fix.sh can test both the same way:
#        DDL | create index ...           (an index it recommends)
#        PROFILE | POST07_STA             (a SQL profile it recommends)
#      Recommendations without a script (e.g. "rewrite the predicate") are in
#      the report only: they are text, for a person to read.
#
# Run as the lab user. Implements nothing: recommendations are only tested,
# and undone, by 06_try_fix.sh.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-07 settings.
load_post07_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

report="${POST07_OUT}/advisor_report.txt"
fixes="${POST07_OUT}/advisor_fixes.txt"

step "1/3 The query's cursor, freshly in the cache"
measure_query "${QUERY_ORIGINAL}" "${POST07_OUT}/measure_for_advisor.txt"
sql_id="$(python3 "${POST07_DIR}/parse_measure.py" --fields "${POST07_OUT}/measure_for_advisor.txt" | sed -n 's/^SQL_ID=//p')"
[[ "${sql_id}" =~ ^[a-z0-9]{13}$ ]] || die "no valid SQL_ID from the measurement: '${sql_id}'."
info "SQL_ID ${sql_id}: $(python3 "${POST07_DIR}/parse_measure.py" "${POST07_OUT}/measure_for_advisor.txt")"

step "2/3 SQL Tuning Advisor (up to ${STA_TIME_LIMIT}s)"
if ! output="$(run_post07_sql tuning_advisor.sql "define sql_id = ${sql_id}")"; then
    echo "${output}" | tail -30 >&2
    die "SQL Tuning Advisor failed."
fi
grep -q '#SCRIPT_END#' <<< "${output}" || { echo "${output}" | tail -30 >&2; die "unexpected output from SQL*Plus."; }
# The report and the script, each from between its markers.
sed -n '/^#REPORT_BEGIN#$/,/^#REPORT_END#$/p' <<< "${output}" | sed '1d;$d' > "${report}"
script="$(sed -n '/^#SCRIPT_BEGIN#$/,/^#SCRIPT_END#$/p' <<< "${output}" | sed '1d;$d')"
sed 's/^/    /' "${report}"

step "3/3 The advisor's implementation script, as fix lines"
{
    # Index recommendations: "create index ...;" lines, one statement each.
    grep -i -E '^[[:space:]]*create[[:space:]]+(unique[[:space:]]+|bitmap[[:space:]]+)?index[[:space:]]' <<< "${script}" \
        | sed -e 's/^[[:space:]]*//' -e 's/;[[:space:]]*$//' -e 's/^/DDL | /' || true
    # A SQL profile recommendation: the script accepts it with DBMS_SQLTUNE.ACCEPT_SQL_PROFILE.
    grep -qi 'accept_sql_profile' <<< "${script}" && echo "PROFILE | POST07_STA" || true
} > "${fixes}"
if [[ -s "${fixes}" ]]; then
    sed 's/^/    /' "${fixes}"
else
    info "(none: no index or profile in the advisor's script; see the report for text-only advice)"
fi
# Anything else in the script (e.g. statistics) is shown, not tested.
others="$(grep -v -i -E '^[[:space:]]*(--|$)|create[[:space:]]+(unique[[:space:]]+|bitmap[[:space:]]+)?index|accept_sql_profile' <<< "${script}" || true)"
[[ -z "${others}" ]] || { info "Also in the script (not tested):"; sed 's/^/      /' <<< "${others}"; }

step "Done"
info "Saved: ${report}"
info "Saved: ${fixes}"
info "Next: ./06_try_fix.sh advisor"
