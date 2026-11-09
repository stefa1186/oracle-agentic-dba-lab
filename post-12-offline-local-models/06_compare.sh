#!/usr/bin/env bash
# =============================================================================
# 06_compare.sh
#
# Cloud vs local, on the newest run of each model (compare.py):
#   1. test A, post 02's prompt: markers from the database's answer key,
#      statements, errors, and statements outside the SQL Firewall
#      allow-list (exported here, per run, from the database)
#   2. test B, post 08's questions: post 08's own scorer, one row per model
#   3. speed: time in model calls, tokens written per second
#
#   ./06_compare.sh             the three tables
#   ./06_compare.sh --answers   the same, then every final answer, as written
#
# Run as the lab user, offline or online. Read-only (the exports are saved
# next to each run: violations.jsonl). Saved to comparison.md.
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
# The database must be up (for the firewall export).
require_database

case "${1:-}" in
    ""|--answers) ;;
    *) die "usage: $0 [--answers]" ;;
esac
[[ -f "${ANSWER_KEY}" ]] || die "no answer key: run ./02_prepare_online.sh first."

# The newest run of each model (test A: post 02's prompt), and of each model
# and attached file (test B: post 08's prompt).
mapfile -t runs_a < <(python3 "${POST12_DIR}/compare.py" select "${POST12_OUT}" "$(basename "$(dirname "${INVENTORY_PROMPT}")")")
mapfile -t runs_b < <(python3 "${POST12_DIR}/compare.py" select "${POST12_OUT}" "$(basename "$(dirname "${TEAM_NOTES_PROMPT}")")")
(( ${#runs_a[@]} > 0 )) || die "no test A runs yet: ./03_cloud_baseline.sh, ./05_run_local.sh"

# Test A's statements outside the allow-list: from the firewall's log, in
# each run's own time window.
for run in "${runs_a[@]}"; do
    read -r start_date start_time end_date end_time <<< "$(run_window_utc "${run}")"
    fetch_violations_jsonl "${start_date} ${start_time}" "${end_date} ${end_time}" > "${run}/violations.jsonl"
done

report="${POST12_OUT}/comparison.md"
{
    echo "# Cloud vs local: post 12"
    echo
    echo "## Test A: post 02's first-session prompt (with tools)"
    echo
    python3 "${POST12_DIR}/compare.py" inventory "${ANSWER_KEY}" "${runs_a[@]}"
    echo
    echo "## Test B: post 08's team note questions (no tools)"
    echo
    if (( ${#runs_b[@]} > 0 )); then
        # Post 08's scorer, with one more column: the model. Its heading is
        # dropped (this file has its own).
        python3 "${POST08_DIR}/score_answers.py" --by-model --runs "${runs_b[@]}" \
            --questions "${POST08_DIR}/questions.txt" --team-notes "${POST08_DIR}/team_notes" | sed '1,2d'
    else
        echo "(no test B runs yet)"
    fi
    echo
    echo "## Speed: both tests"
    echo
    python3 "${POST12_DIR}/compare.py" speed "${runs_a[@]}" "${runs_b[@]}"
} > "${report}"
cat "${report}"

if [[ "${1:-}" == "--answers" ]]; then
    step "Test A: the answers"
    python3 "${POST12_DIR}/compare.py" answers "${runs_a[@]}"
    if (( ${#runs_b[@]} > 0 )); then
        step "Test B: the answers"
        python3 "${POST12_DIR}/compare.py" answers "${runs_b[@]}"
    fi
fi

step "Done"
info "Saved: ${report}"
