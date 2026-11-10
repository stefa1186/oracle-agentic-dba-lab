#!/usr/bin/env bash
# =============================================================================
# 04_run_agent.sh
#
# Asks every question, at both metadata levels, to every model in models.txt,
# REPEATS times, through the harness, like part 8: the input file attached to
# 03_prompt.md, and no tools (the model only writes SQL; it runs nothing).
# All runs of one call go into one set folder: set_<UTC time>.
# Run as the lab user, after 02_build_inputs.sh and agent-harness/setup_harness.sh.
#   ./04_run_agent.sh            every question
#   ./04_run_agent.sh S1 T3      only these
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01, 02 and 13 settings.
load_post13_config
# Must be the lab user.
require_lab_user

# The inputs come from 02_build_inputs.sh.
inputs="${OUT_DIR}/inputs"
[[ -d "${inputs}" ]] || die "no inputs yet. Run ./02_build_inputs.sh first."
# The question ids: the ones given, or all.
ids=("$@")
(( ${#ids[@]} )) || mapfile -t ids < <(grep -v '^#' "${POST13_DIR}/questions.txt" | cut -d'|' -f1 | grep -v '^$')
# One set folder for this call, under the harness's output folder.
set_name="post-13-nl2sql-select-ai/set_$(date -u +%Y%m%dT%H%M%SZ)"
for meta in bare comments; do
    for qid in "${ids[@]}"; do
        step "${meta}, ${qid}"
        # The harness, as in every part: every model in models.txt, REPEATS runs.
        ( cd "${POST13_DIR}/../agent-harness" && ./run_matrix.sh -r "${REPEATS}" -m "${POST13_DIR}/models.txt" -o "${set_name}" \
              "${POST13_DIR}/03_prompt.md" -- --attach "${inputs}/input_${meta}_${qid}.txt" --allow-tools NONE ) \
            | grep -E '^(---|ERROR)' || true
    done
done
info "Runs: ${HOME}/oracle-agentic-dba-lab/output/${set_name}. Next: ./05_grade.sh"
