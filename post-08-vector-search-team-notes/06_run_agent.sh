#!/usr/bin/env bash
# =============================================================================
# 06_run_agent.sh
#
# Runs the agent on every question twice, through the harness's matrix:
#   without team notes:  question_<id>.txt attached (the question only)
#   with team notes:     context_<id>.txt attached (question + the TOP_K chunks)
# Same prompt (05_prompt.md), no tools: the only difference between the two
# runs of a question is the team note excerpts.
#
#   ./06_run_agent.sh              every question, with and without, 1 run each
#   ./06_run_agent.sh -r 3         ... 3 runs each
#
# Run as the lab user, after ./04_search.sh. Extra options are passed to
# run_matrix.sh (e.g. -m models.txt to compare models).
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-08 settings.
load_post08_config
# Must be the lab user.
require_lab_user

harness="${POST08_DIR}/../agent-harness"
for id in $(question_ids); do
    for kind in question context; do
        file="${POST08_OUT}/${kind}_${id}.txt"
        [[ -f "${file}" ]] || die "no ${file}: run ./04_search.sh first."
        step "Question '${id}', $( [[ "${kind}" == question ]] && echo 'WITHOUT' || echo 'WITH') team notes"
        # The harness from its own folder, as everywhere in the lab.
        ( cd "${harness}" && ./run_matrix.sh "$@" "${POST08_DIR}/05_prompt.md" -- --attach "${file}" --allow-tools NONE )
    done
done

step "Done"
info "Next: ./07_score.sh"
