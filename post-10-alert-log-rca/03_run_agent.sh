#!/usr/bin/env bash
# =============================================================================
# 03_run_agent.sh
#
# Runs the agent on the incident (03_prompt.md), through the harness's matrix,
# in APPROVAL mode (--confirm): before every tool call, the harness shows what
# the model says it wants to do and why, then the exact call, and waits:
#   Approve sql_run {"sql": "..."}? [y/N]
# Only "y" runs it. Anything else (Enter included) rejects it, and the model
# gets "TOOL ERROR: the human operator rejected this tool call." instead.
# Every decision, and how long it took, is logged in the run (event "approval").
#
#   ./03_run_agent.sh          one run
#
# Interactive: run it in a terminal. Extra options go to run_matrix.sh. Run
# as the lab user, while the incident is running (./02_create_incident.sh).
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

# Approval needs a human at a terminal.
[[ -t 0 ]] || die "this run asks for approval at every step: start it from a terminal."
# The incident must be running, or there is nothing to investigate.
[[ -f "${INCIDENT_FILE}" ]] || die "no incident yet: run ./02_create_incident.sh first."
info "Incident: $(cat "${INCIDENT_FILE}")"

# The harness from its own folder, as everywhere in the lab. With
# --final-on-limit, a run that hits MAX_STEPS still ends with an answer.
( cd "${POST10_DIR}/../agent-harness" && ./run_matrix.sh "$@" "${POST10_DIR}/03_prompt.md" -- --confirm --final-on-limit )

step "Done"
info "Next: ./04_dba_investigation.sh, then ./05_review_run.sh"
