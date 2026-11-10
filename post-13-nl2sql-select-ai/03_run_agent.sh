#!/usr/bin/env bash
# =============================================================================
# 03_run_agent.sh
#
# Asks every question to every model in models.txt, REPEATS times, through the
# harness, as in every part: 02_prompt.md with the question attached, and the
# agent reads SH itself through SQLcl's MCP server (saved connection "agent").
# All runs of one call go into one set folder: set_<UTC time>.
# Run as the lab user, after 01_setup.sh and agent-harness/setup_harness.sh.
#   ./03_run_agent.sh            every question
#   ./03_run_agent.sh S1 T3      only these
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

# One small file per question: the question alone, attached to the prompt.
inputs="${OUT_DIR}/inputs"
install -d -m 700 "${inputs}"
while IFS='|' read -r qid _group question _reference; do
    # Skip comments and blank lines.
    [[ -z "${qid}" || "${qid}" == \#* ]] && continue
    printf '%s\n' "${question}" > "${inputs}/question_${qid}.txt"
done < "${POST13_DIR}/questions.txt"
# The question ids: the ones given, or all.
ids=("$@")
(( ${#ids[@]} )) || mapfile -t ids < <(grep -v '^#' "${POST13_DIR}/questions.txt" | cut -d'|' -f1 | grep -v '^$')
# One set folder for this call, under the harness's output folder.
set_name="post-13-nl2sql-select-ai/set_$(date -u +%Y%m%dT%H%M%SZ)"
for qid in "${ids[@]}"; do
    step "${qid}"
    # The harness, as in every part: every model in models.txt, REPEATS runs,
    # the default MCP tools.
    ( cd "${POST13_DIR}/../agent-harness" && ./run_matrix.sh -r "${REPEATS}" -m "${POST13_DIR}/models.txt" -o "${set_name}" \
          "${POST13_DIR}/02_prompt.md" -- --attach "${inputs}/question_${qid}.txt" ) \
        | grep -E '^(---|ERROR)' || true
done
info "Runs: ${HOME}/oracle-agentic-dba-lab/output/${set_name}. Next: ./04_grade.sh"
