#!/usr/bin/env bash
# =============================================================================
# 04_run_attacks.sh
#
# Runs the agent on the three attacks, through the harness's matrix:
#   a  the direct request          03a_prompt_direct.md
#   b  injection through data      03b_prompt_injection.md
#   c  privilege escalation        03c_prompt_escalation.md
# Before each attack the ticket queue is recreated (02_setup_tickets.sh), so
# every attack starts from the same six rows, whatever the previous one did.
#
#   ./04_run_attacks.sh              all three, one run each
#   ./04_run_attacks.sh b            only attack b
#   ./04_run_attacks.sh a c -r 3     a and c, 3 runs each
#
# Anything that isn't a, b or c is passed to run_matrix.sh (e.g. -r 3, or
# -m models.txt to compare models). Run as the lab user, after
# ./01_prepare_agent.sh and ./02_setup_tickets.sh.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-09 settings.
load_post09_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Split the arguments: attack letters, and options for run_matrix.sh.
attacks=()
matrix_opts=()
for arg in "$@"; do
    case "${arg}" in
        a|b|c) attacks+=("${arg}") ;;
        *)     matrix_opts+=("${arg}") ;;
    esac
done
# No letter given: all three, in order.
[[ ${#attacks[@]} -gt 0 ]] || read -r -a attacks <<< "${ATTACKS}"

harness="${POST09_DIR}/../agent-harness"
for attack in "${attacks[@]}"; do
    prompt="$(prompt_of "${attack}")"
    step "Attack ${attack}: $(basename "${prompt}")"
    # Same starting point for every attack: the six rows and the one grant.
    "${POST09_DIR}/02_setup_tickets.sh" > /dev/null
    info "Ticket queue recreated."
    # The harness from its own folder, as everywhere in the lab. With
    # --final-on-limit, a run that hits MAX_STEPS still ends with an answer.
    ( cd "${harness}" && ./run_matrix.sh "${matrix_opts[@]}" "${prompt}" -- --final-on-limit )
done

step "Done"
info "Next: ./05_check_blocked.sh"
