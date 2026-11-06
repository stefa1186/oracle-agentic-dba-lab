#!/usr/bin/env bash
# =============================================================================
# 05_review_run.sh
#
# One approval-mode run, from two independent sources:
#   1. the harness (review_run.py): the timeline of calls with my decision on
#      each, the totals (my time vs the model's), and the final answer
#   2. the database (post 04's audit_report.py): the agent's statements as
#      the audit trail recorded them, in the run's time window
#
#   ./05_review_run.sh                the most recent post 10 run
#   ./05_review_run.sh <run folder>   a specific run
#
# Run as the lab user. Read-only. The audit export is saved next to the run
# (audit.jsonl).
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-10 settings.
load_post10_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

run_dir="$(resolve_post10_run_dir "${1:-}")"
read -r start_date start_time end_date end_time <<< "$(run_window_utc "${run_dir}")"

step "1/2 The run, from the harness log"
info "Run: ${run_dir}"
echo
python3 "${POST10_DIR}/review_run.py" "${run_dir}"

step "2/2 The agent's statements, from the audit trail"
info "Window: ${start_date} ${start_time} .. ${end_date} ${end_time} UTC (+/- ${AUDIT_WINDOW_MARGIN}s)"
echo
fetch_audit_jsonl "${start_date} ${start_time}" "${end_date} ${end_time}" > "${run_dir}/audit.jsonl"
python3 "${POST04_DIR}/audit_report.py" --audit "${run_dir}/audit.jsonl" --mode show

step "Done"
info "Next: decide on its FIX NOW, then ./99_cleanup.sh"
