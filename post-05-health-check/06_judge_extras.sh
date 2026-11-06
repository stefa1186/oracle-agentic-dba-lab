#!/usr/bin/env bash
# =============================================================================
# 06_judge_extras.sh
#
# Prints the facts needed to judge the agent's findings that are not on my
# checklist (judge_extras.sql): room to grow per tablespace, whether accounts
# with DBA or OPEN status can log in at all, memory parameters in the CDB vs.
# the PDB, where archived logs go, and where statistics are missing.
# Saved to output/post-05-health-check/judge_extras.txt.
#
# Run as the lab user. Read-only: SQL runs as SYSDBA but changes nothing.
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

step "Facts for judging the agent's extra findings"
# Run the queries; keep everything they printed, for the result or for the error.
if ! output="$(run_post05_sql judge_extras.sql)"; then
    echo "${output}" >&2
    die "the queries failed."
fi
# The marker proves the script ran to the end.
grep -q JUDGE_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
# Save without the marker lines, then show.
grep -v -E 'JUDGE_COMPLETE|^MARKER|^-+$' <<< "${output}" > "${POST05_OUT}/judge_extras.txt"
cat "${POST05_OUT}/judge_extras.txt"

step "Done"
info "Saved: ${POST05_OUT}/judge_extras.txt"
