#!/usr/bin/env bash
# =============================================================================
# 03_audit_trail.sh
#
# Shows what the DATABASE recorded during one agent run, in the run's time
# window: a summary (agent statements, SQLcl housekeeping, logon/logoff),
# then the agent's statements one per line (time, action, result, model, SQL).
#
#   ./03_audit_trail.sh                       the most recent post 04 run
#   ./03_audit_trail.sh <run folder>          a specific run (the folder with events.jsonl)
#   ./03_audit_trail.sh [<run folder>] --all  every record, SQLcl housekeeping included
#
# Run as the lab user. Read-only. The raw export is also saved next to the
# run as audit.jsonl (one JSON object per record), so the evidence stays with the run.
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

# Arguments: an optional run folder and an optional --all, in any order.
run_arg=""
all_flag=()
for arg in "$@"; do
    case "${arg}" in
        --all) all_flag=(--all) ;;
        *)     run_arg="${arg}" ;;
    esac
done

# Which run, and its time window.
run_dir="$(resolve_run_dir "${run_arg}")"
read -r start_date start_time end_date end_time <<< "$(run_window_utc "${run_dir}")"

step "Audit records for ${AGENT_DB_USER}"
info "Run:    ${run_dir}"
info "Window: ${start_date} ${start_time} .. ${end_date} ${end_time} UTC (+/- ${AUDIT_WINDOW_MARGIN}s)"
echo

# Export the records next to the run, then print them readably.
fetch_audit_jsonl "${start_date} ${start_time}" "${end_date} ${end_time}" > "${run_dir}/audit.jsonl"
# The run's events.jsonl names its model: records tagged by another client in
# the same window (a replay, another run) are then counted separately.
python3 "${POST04_DIR}/audit_report.py" --audit "${run_dir}/audit.jsonl" --mode show \
    --events "${run_dir}/events.jsonl" "${all_flag[@]}"

step "Saved"
info "${run_dir}/audit.jsonl"
info "Next: ./04_compare.sh ${run_dir}"
