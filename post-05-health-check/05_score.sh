#!/usr/bin/env bash
# =============================================================================
# 05_score.sh
#
# Scores one agent run against the DBA checklist: writes scorecard.md into
# the run folder (with suggested marks to confirm by hand) and prints it.
#
#   ./05_score.sh                 the most recent post 05 run
#   ./05_score.sh <run folder>    a specific run (the folder with events.jsonl)
#
# Run as the lab user. Reads files only: no database access needed.
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

# The inputs must exist.
[[ -f "${ANSWER_KEY}" ]]    || die "no answer key: run ./02_seed_known_problems.sh first."
[[ -f "${CHECKLIST_OUT}" ]] || die "no checklist output: run ./03_dba_checklist.sh first."
# Which run.
run_dir="$(resolve_post05_run_dir "${1:-}")"

step "Scoring ${run_dir}"
# Write the scorecard next to the run, then show it.
python3 "${POST05_DIR}/score.py" \
    --checklist "${CHECKLIST_OUT}" \
    --answer-key "${ANSWER_KEY}" \
    --events "${run_dir}/events.jsonl" > "${run_dir}/scorecard.md"
cat "${run_dir}/scorecard.md"

step "Done"
info "Saved: ${run_dir}/scorecard.md (edit the marks there)"
info "Step by step: python3 ../agent-harness/run_summary.py ${run_dir}"
info "What the database recorded: ../post-04-auditing-the-agent/03_audit_trail.sh ${run_dir}"
