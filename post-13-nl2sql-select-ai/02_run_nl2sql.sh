#!/usr/bin/env bash
# =============================================================================
# 02_run_nl2sql.sh
#
# Asks every question of questions.txt to every model in MODELS, REPEATS
# times, once with bare metadata (table and column names and types) and once
# with the comments too, and grades each generated query against the
# reference. One run folder per call, under the post's output folder.
#
# Run as the lab user, after 01_setup.sh and the harness's setup_harness.sh
# (Python environment, OpenRouter key in agent-harness/.env).
#   ./02_run_nl2sql.sh              every question
#   ./02_run_nl2sql.sh S1 T3        only these questions
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

# The harness's Python environment (it has the OpenAI-compatible client).
python="${POST13_DIR}/../agent-harness/.venv/bin/python"
[[ -x "${python}" ]] || die "no Python environment. Run agent-harness/setup_harness.sh first."
# The read-only user's password file comes from 01_setup.sh.
[[ -f "${RO_PASSWORD_FILE}" ]] || die "no ${RO_USER} yet. Run ./01_setup.sh first."

# The settings the Python script needs, as environment variables.
export DB_CONTAINER RO_USER RO_PASSWORD_FILE OUT_DIR MODELS REPEATS
export HARNESS_ENV="${POST13_DIR}/../agent-harness/.env"
export QUESTIONS="${POST13_DIR}/questions.txt"
# -I: isolated mode, no user site packages, no current folder on the path.
exec "${python}" -I "${POST13_DIR}/nl2sql.py" "$@"
