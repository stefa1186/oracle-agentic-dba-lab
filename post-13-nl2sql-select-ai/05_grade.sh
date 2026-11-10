#!/usr/bin/env bash
# =============================================================================
# 05_grade.sh
#
# Grades every answer of a set of runs (the newest, or the folder given): the
# generated SQL runs as the read-only user, and MINUS in both directions
# compares it with the reference. PASS, WRONG, ERROR or SHAPE, into
# results.csv in the set folder. Run as the lab user. Changes nothing in SH.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01, 02 and 13 settings.
load_post13_config
# Must be the lab user (this also sets XDG_RUNTIME_DIR for podman).
require_lab_user

# The set: the folder given, or the newest one.
set_dir="${1:-$(ls -d "${OUT_DIR}"/set_* 2>/dev/null | tail -1)}"
[[ -d "${set_dir}" ]] || die "no set of runs. Run ./04_run_agent.sh first."
echo "Set: ${set_dir}"
# The settings grade.py reads; -I: isolated mode.
export DB_CONTAINER RO_USER RO_PASSWORD_FILE QUESTIONS="${POST13_DIR}/questions.txt"
python3 -I "${POST13_DIR}/grade.py" grade "${set_dir}"
info "Next: ./06_report.sh"
