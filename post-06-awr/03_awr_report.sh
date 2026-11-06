#!/usr/bin/env bash
# =============================================================================
# 03_awr_report.sh
#
# Produces, for the snapshots saved by 02_generate_load.sh:
#   - output/post-06-awr/awr_report.txt: the standard AWR text report, exactly
#     as AWR writes it. This is what the agent reads, attached to its prompt.
#   - output/post-06-awr/answer_key.txt: the two planted problems, and what AWR
#     measured for them, read from the DBA_HIST views directly.
#   - output/post-06-awr/awr_report_noaddm.txt: the same report WITHOUT ADDM's
#     sections. In 26ai the AWR report includes ADDM's findings, which name
#     the planted problems; without them the agent has to diagnose from the
#     raw numbers. Cut mechanically, then checked: no "ADDM" may remain.
# Then prints the size of the report in characters and estimated tokens.
#
# Run as the lab user. Read-only: SQL runs as SYSDBA but changes nothing.
# Safe to rerun: both files are replaced.
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

# The snapshot pair.
read -r begin_snap end_snap <<< "$(read_snapshots)"

step "AWR report, snapshots ${begin_snap} to ${end_snap}"
if ! output="$(run_post06_sql awr_report.sql "define begin_snap = ${begin_snap}" "define end_snap = ${end_snap}")"; then
    echo "${output}" | tail -30 >&2
    die "the AWR report failed."
fi
# The marker proves the script ran to the end.
grep -q REPORT_COMPLETE <<< "${output}" || { echo "${output}" | tail -30 >&2; die "unexpected output from SQL*Plus."; }

# The report: everything between the markers, nothing else.
sed -n '/^#AWR_BEGIN#$/,/^#AWR_END#$/p' <<< "${output}" | sed '1d;$d' > "${AWR_REPORT}"
[[ -s "${AWR_REPORT}" ]] || die "the report is empty."

# The answer key: the planted problems (fixed), then what AWR measured (KEY lines).
{
    echo "PLANTED | ROW_LOCK | 1 session holds a lock on ${AWR_SCHEMA}.ACCOUNTS row 1 for ${AWR_LOCK_HOLD_SECONDS}s at a time; ${AWR_LOCK_WAITERS} sessions keep updating the same row"
    echo "PLANTED | HARD_PARSE | ${AWR_LITERAL_SESSIONS} session(s) run the same query on ${AWR_SCHEMA}.ORDERS with a new literal every time (no bind variable)"
    grep '^KEY' <<< "${output}" | sed 's/[[:space:]]*$//'
} > "${ANSWER_KEY}"

step "Answer key"
sed 's/^/    /' "${ANSWER_KEY}"

step "The report"
chars="$(wc -m < "${AWR_REPORT}")"
lines="$(wc -l < "${AWR_REPORT}")"
info "${AWR_REPORT}"
# About four characters per token for English text: a rough guide, not a count.
info "${lines} lines, ${chars} characters, roughly $(( chars / 4 )) tokens."
info "The section every DBA reads first:"
# Print the Top 10 Foreground Events section, if present, as AWR wrote it.
awk '/^Top 10 Foreground Events/ { show = 1 } show { print "    " $0; n++ } n > 18 { exit }' "${AWR_REPORT}"

step "The report without ADDM"
# Three pieces, as they appear in the 26ai text report:
#   1. the "Top ADDM Findings by Average Active Sessions" block near the top:
#      from its title to the blank line after its table (at most 40 lines)
#   2. the "-> ADDM Reports" entry in the report's table of contents
#   3. the "ADDM Reports" section: from its title to "End of Report" (kept),
#      or to the end of the file
awk '
    # 1. The findings block: skip from the title...
    /^Top ADDM Findings by Average Active Sessions/ { block = 1; dashes = 0; n = 0; next }
    block {
        n++
        # ...past the dashed line under the column headings...
        if ($0 ~ /^-+( +-+)*[[:space:]]*$/) dashes = 1
        # ...to the first blank line after it (or 40 lines, as a safety net).
        else if ((dashes && $0 ~ /^[[:space:]]*$/) || n >= 40) block = 0
        next
    }
    # 2. The table-of-contents entry.
    /^-> ADDM Reports/ { next }
    # 3. The ADDM Reports section, to the end of the report.
    /^ADDM Reports[[:space:]]*$/ { tail = 1; next }
    tail { if ($0 ~ /^End of Report/) { tail = 0; print }; next }
    { print }
' "${AWR_REPORT}" > "${AWR_REPORT_NOADDM}"
# The check: not one mention of ADDM may be left, or the test is not what it claims.
if grep -qi 'ADDM' "${AWR_REPORT_NOADDM}"; then
    grep -n -i 'ADDM' "${AWR_REPORT_NOADDM}" | head -10 | sed 's/^/    /' >&2
    die "ADDM text left in ${AWR_REPORT_NOADDM}: the cut needs adjusting for this report layout."
fi
removed=$(( $(wc -l < "${AWR_REPORT}") - $(wc -l < "${AWR_REPORT_NOADDM}") ))
info "${AWR_REPORT_NOADDM}"
info "$(wc -l < "${AWR_REPORT_NOADDM}") lines, ${removed} removed; no mention of ADDM left."

step "Done"
info "Next: run the agent on either report (see README), then ./05_check_claims.sh"
