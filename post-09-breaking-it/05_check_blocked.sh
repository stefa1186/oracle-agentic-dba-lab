#!/usr/bin/env bash
# =============================================================================
# 05_check_blocked.sh
#
# What each attack did and what stopped it, from three independent sources
# (attack_report.py): the harness log, the audit trail, and SQL Firewall's
# violation log, each in the run's own time window.
#
#   ./05_check_blocked.sh                    the newest run of each attack
#   ./05_check_blocked.sh <run folder> <a|b|c>   one specific run
#
# Run as the lab user. Read-only. The exports are saved next to each run
# (audit.jsonl, violations.jsonl), so the evidence stays with the run.
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

# Export one run's evidence and print its report.
report_run() {
    local run_dir="$1" attack="$2" start_date start_time end_date end_time
    read -r start_date start_time end_date end_time <<< "$(run_window_utc "${run_dir}")"
    step "Attack ${attack}: $(basename "$(prompt_of "${attack}")")"
    info "Run:    ${run_dir}"
    info "Window: ${start_date} ${start_time} .. ${end_date} ${end_time} UTC (+/- ${AUDIT_WINDOW_MARGIN}s)"
    echo
    # The two database-side exports, kept with the run.
    fetch_audit_jsonl      "${start_date} ${start_time}" "${end_date} ${end_time}" > "${run_dir}/audit.jsonl"
    fetch_violations_jsonl "${start_date} ${start_time}" "${end_date} ${end_time}" > "${run_dir}/violations.jsonl"
    python3 "${POST09_DIR}/attack_report.py" "${run_dir}" "${attack}"
}

case $# in
    2)
        # One given run: it must be a harness run folder.
        [[ -f "$1/events.jsonl" ]] || die "$1 has no events.jsonl: not a harness run folder."
        prompt_of "$2" > /dev/null
        report_run "$(cd "$1" && pwd)" "$2"
        ;;
    0)
        # The newest run of each attack that has one.
        found=0
        for attack in ${ATTACKS}; do
            run_dir="$(latest_run_of "${attack}")"
            if [[ -z "${run_dir}" ]]; then
                warn "no run of attack ${attack} yet: ./04_run_attacks.sh ${attack}"
                continue
            fi
            report_run "${run_dir}" "${attack}"
            found=$((found + 1))
        done
        (( found > 0 )) || die "no attack runs found under ${POST09_OUT}. Run ./04_run_attacks.sh first."
        ;;
    *)
        die "usage: $0 [<run folder> <a|b|c>]"
        ;;
esac

step "Done"
info "Next: ./06_firewall_bypass.sh"
