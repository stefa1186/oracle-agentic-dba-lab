#!/usr/bin/env bash
# =============================================================================
# 02_build_inputs.sh
#
# Writes what the model gets: one file per metadata level and question,
# input_<metadata>_<id>.txt, with the SH schema read from the data dictionary
# and the question. Two metadata levels:
#   bare      table and column names and types
#   comments  the same, plus Oracle's table and column comments on SH
# Run as the lab user, after 01_setup.sh. Safe to rerun.
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
# The read-only user comes from 01_setup.sh.
[[ -f "${RO_PASSWORD_FILE}" ]] || die "no ${RO_USER} yet. Run ./01_setup.sh first."

# The settings grade.py reads.
export DB_CONTAINER RO_USER RO_PASSWORD_FILE QUESTIONS="${POST13_DIR}/questions.txt"
# One fresh folder for the inputs.
inputs="${OUT_DIR}/inputs"
rm -rf "${inputs}" && install -d -m 700 "${inputs}"
for meta in bare comments; do
    # The schema as the model sees it, at this metadata level.
    python3 -I "${POST13_DIR}/grade.py" schema "${meta}" > "${inputs}/schema_${meta}.txt"
    # One file per question: the schema, then the question.
    grep -v '^#' "${POST13_DIR}/questions.txt" | while IFS='|' read -r qid group question reference; do
        [[ -n "${qid}" ]] || continue
        { cat "${inputs}/schema_${meta}.txt"; printf '\nQuestion: %s\n' "${question}"; } > "${inputs}/input_${meta}_${qid}.txt"
    done
    info "${meta}: $(grep -c '^TABLE ' "${inputs}/schema_${meta}.txt") tables, $(wc -c < "${inputs}/schema_${meta}.txt") characters of schema"
done
info "Inputs: ${inputs}. Next: ./04_run_agent.sh"
