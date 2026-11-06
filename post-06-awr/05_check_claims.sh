#!/usr/bin/env bash
# =============================================================================
# 05_check_claims.sh
#
# Checks one agent run against the AWR report it read: are its quotes really
# in the report, which numbers in its answer the report doesn't contain, and
# did it find the two planted problems. Writes scorecard.md into the run
# folder (with suggested marks to confirm by hand) and prints it.
#
#   ./05_check_claims.sh                 the most recent post 06 run
#   ./05_check_claims.sh <run folder>    a specific run (the folder with events.jsonl)
#
# Run as the lab user. Reads files only: no database access needed.
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

# The inputs must exist.
[[ -f "${AWR_REPORT}" ]] || die "no AWR report: run ./03_awr_report.sh first."
[[ -f "${ANSWER_KEY}" ]] || die "no answer key: run ./03_awr_report.sh first."
# Which run.
run_dir="$(resolve_post06_run_dir "${1:-}")"
# The report THIS run was given (logged by the harness in run_start), so a
# run on the report without ADDM is checked against that one. Older runs
# without the record fall back to the full report.
report="$(python3 - "${run_dir}/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(line) if line.strip() else {}
    if e.get("event") == "run_start" and e.get("attached"):
        print(e["attached"][0]["file"])
        break
PY
)"
report="${report:-${AWR_REPORT}}"
[[ -f "${report}" ]] || die "the report this run read is gone: ${report}"
info "Report this run read: ${report}"

step "Checking ${run_dir}"
python3 "${POST06_DIR}/check_claims.py" \
    --report "${report}" \
    --events "${run_dir}/events.jsonl" \
    --answer-key "${ANSWER_KEY}" > "${run_dir}/scorecard.md"
cat "${run_dir}/scorecard.md"

step "Done"
info "Saved: ${run_dir}/scorecard.md (edit the marks there)"
info "Step by step: python3 ../agent-harness/run_summary.py ${run_dir}"
