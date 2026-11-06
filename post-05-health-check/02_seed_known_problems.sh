#!/usr/bin/env bash
# =============================================================================
# 02_seed_known_problems.sh
#
# Seeds the problems the health check should find (seed_known_problems.sql)
# and saves the answer key, read back from the dictionary, to
# output/post-05-health-check/answer_key.txt.
#
# Run as the lab user. SQL runs as SYSDBA inside the container (no password).
# Deterministic: drops what a previous run created, then recreates it.
# Everything it creates lives in its own schema and tablespace (HC_*), and
# 99_cleanup.sh removes it.
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

step "Seeding known problems in FREEPDB1 (schema ${HC_SCHEMA}, tablespace ${HC_TABLESPACE})"
# Run the seed; keep everything it printed, for the answer key or for the error.
if ! output="$(run_post05_sql seed_known_problems.sql)"; then
    # Show what SQL*Plus said, then stop.
    echo "${output}" >&2
    die "seeding failed."
fi
# The marker proves the script ran to the end.
grep -q SEED_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }

step "Answer key"
# Keep only the answer-key lines, trimmed of trailing spaces.
grep '^SEEDED' <<< "${output}" | sed 's/[[:space:]]*$//' > "${ANSWER_KEY}"
# Show them.
sed 's/^/    /' "${ANSWER_KEY}"
# Six problems are seeded; fewer lines means one of them didn't take.
count="$(wc -l < "${ANSWER_KEY}")"
[[ "${count}" -eq 6 ]] || die "expected 6 seeded problems, found ${count}: check the output above."

step "Done"
info "Saved: ${ANSWER_KEY}"
info "Next: ./03_dba_checklist.sh"
