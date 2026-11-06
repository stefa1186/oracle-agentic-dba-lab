#!/usr/bin/env bash
# =============================================================================
# 03_cloud_baseline.sh
#
# The baseline: the series' cloud model (CLOUD_MODELS, through OpenRouter) on
# both tests, in the same lab state and with the same limits as the local
# models will get, so only the model changes:
#   test A  post 02's first-session prompt, with tools          (1 run)
#   test B  post 08's runbook questions, without and with runbooks (6 runs)
#
# Run as the lab user, after ./02_prepare_online.sh, while still ONLINE
# (OpenRouter is on the internet). Needs OPENROUTER_API_KEY in
# agent-harness/.env. Every rerun adds new runs; ./06_compare.sh uses the
# newest.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-12 settings.
load_post12_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# The answer key and test B's files must exist: 02 makes them.
[[ -f "${ANSWER_KEY}" ]] || die "no answer key: run ./02_prepare_online.sh first."
# The cloud is on the internet.
curl -fsS -o /dev/null --max-time 20 https://openrouter.ai/api/v1/models \
    || die "the lab user can't reach openrouter.ai: the baseline needs to be online."

for model in ${CLOUD_MODELS}; do
    run_tests openrouter "${model}"
done
# Runs that ended with an error are results too: say how many.
(( FAILED_RUNS == 0 )) || warn "${FAILED_RUNS} run(s) ended with an error; ./06_compare.sh shows how each run ended."

step "Done"
info "Runs: ${POST12_OUT}/"
info "Next: go OFFLINE. As root: post-01-why-and-the-cage/00_root_setup.sh --offline"
info "      then, as the lab user: ./04_prove_offline.sh"
