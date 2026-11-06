#!/usr/bin/env bash
# =============================================================================
# 04_compare.sh
#
# Three records of the same agent run, side by side:
#   1. what the harness SENT (events.jsonl: every sql_run call)
#   2. what the DATABASE recorded (UNIFIED_AUDIT_TRAIL)
#   3. what the AGENT SAID it did (its final answer)
#
# For each statement the agent sent: was it recorded, and with which return
# code? Which statements did the database record that the agent never
# mentioned (SQLcl's own connect-time SQL, logons)?
#
#   ./04_compare.sh                 the most recent post 04 run
#   ./04_compare.sh <run folder>    a specific run
#
# Oracle analogy: "I only ran a SELECT", checked against the redo.
#
# Run as the lab user. Read-only.
# Exit code: 0 if every statement the agent sent is in the audit trail, 1 if not.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-04 settings.
load_post04_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Which run, and its time window.
run_dir="$(resolve_run_dir "${1:-}")"
read -r start_date start_time end_date end_time <<< "$(run_window_utc "${run_dir}")"

step "Harness log vs audit trail vs the agent's own account"
info "Run: ${run_dir}"
echo

# Fresh export of the window (the evidence is saved with the run).
fetch_audit_jsonl "${start_date} ${start_time}" "${end_date} ${end_time}" > "${run_dir}/audit.jsonl"
# Reconcile; the exit code says whether anything the agent sent is missing.
python3 "${POST04_DIR}/audit_report.py" --audit "${run_dir}/audit.jsonl" --mode compare --events "${run_dir}/events.jsonl"
