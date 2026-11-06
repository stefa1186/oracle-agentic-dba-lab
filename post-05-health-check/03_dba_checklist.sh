#!/usr/bin/env bash
# =============================================================================
# 03_dba_checklist.sh
#
# Runs my own health check (dba_checklist.sql) on the same database the agent
# will check, and saves the result to output/post-05-health-check/checklist.txt.
# Then checks the checklist itself: every seeded problem in the answer key
# must appear among its findings, or the checklist is not a fair yardstick.
#
# Run as the lab user. Read-only: SQL runs as SYSDBA but changes nothing.
# Safe to rerun; checklist.txt is replaced by the latest run.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-05 settings.
load_post05_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

step "DBA checklist on FREEPDB1"
# Run the checklist; keep everything it printed, for the result or for the error.
if ! output="$(run_post05_sql dba_checklist.sql)"; then
    # Show what SQL*Plus said, then stop.
    echo "${output}" >&2
    die "the checklist failed."
fi
# The marker proves the script ran to the end.
grep -q CHECKLIST_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
# Keep only the result lines, trimmed of trailing spaces.
grep -E '^(FINDING|OK)' <<< "${output}" | sed 's/[[:space:]]*$//' > "${CHECKLIST_OUT}"
# Show them.
sed 's/^/    /' "${CHECKLIST_OUT}"

step "Summary"
# Count both kinds of line ("|| true": grep -c exits 1 when it counts zero).
findings="$(grep -c '^FINDING' "${CHECKLIST_OUT}" || true)"
oks="$(grep -c '^OK' "${CHECKLIST_OUT}" || true)"
info "${findings} finding(s), ${oks} check(s) without findings."

step "Does the checklist find every seeded problem?"
if [[ ! -f "${ANSWER_KEY}" ]]; then
    # Without an answer key there's nothing to compare: say so, don't fail.
    warn "no answer key yet: run ./02_seed_known_problems.sh first."
else
    missing=0
    # Each answer-key line: SEEDED | category | object | what. Compare on category + object.
    while IFS='|' read -r _ cat obj _; do
        # Trim the spaces around the fields.
        cat="$(xargs <<< "${cat}")"; obj="$(xargs <<< "${obj}")"
        # Same category and same object, as a whole field, on a FINDING line.
        if awk -F'|' -v c="${cat}" -v o="${obj}" '
               # Trim the fields, then compare.
               { gsub(/^ +| +$/, "", $1); gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $3) }
               $1 == "FINDING" && $2 == c && $3 == o { hit = 1 }
               END { exit hit ? 0 : 1 }' "${CHECKLIST_OUT}"; then
            info "found:   ${cat} ${obj}"
        else
            warn "MISSED by the checklist: ${cat} ${obj}"
            missing=$((missing + 1))
        fi
    done < "${ANSWER_KEY}"
    # A checklist that misses a seeded problem can't be used to score the agent.
    (( missing == 0 )) || die "${missing} seeded problem(s) missed by the checklist: fix dba_checklist.sql before scoring."
    info "PASS: every seeded problem is among the checklist's findings."
fi

step "Done"
info "Saved: ${CHECKLIST_OUT}"
info "Next: run the agent (see README), then ./05_score.sh"
