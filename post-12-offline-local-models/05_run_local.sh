#!/usr/bin/env bash
# =============================================================================
# 05_run_local.sh
#
# The same two tests as the cloud baseline, with each local model, OFFLINE:
#   test A  post 02's first-session prompt, with tools          (1 run)
#   test B  post 08's team note questions, without and with team notes (6 runs)
# Same prompts, same lab state, same limits (TEST_* settings): only the
# model, and where it runs, change. Two settings follow where the model runs
# (env.example): no retries after a temporary error, and thinking switched
# off (on this CPU, a thinking 4B ran into the 30-minute timeout at step 1).
# A run that ends with an error is a result: it is counted, and the next one
# starts.
#
# Before and after, the policy's drop counter: if anything in the lab (the
# harness, SQLcl, the model server, the database) tried to reach the
# internet during the runs, the counter grows. It is the evidence that
# nothing left the server, and that nothing tried.
#
# Refuses to start unless the lab user is offline (./04_prove_offline.sh).
# Run as the lab user. Slow on a CPU: the time each model took is printed.
# Every rerun adds new runs; ./06_compare.sh uses the newest.
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

# Offline, or nothing: that's the point of this test.
[[ "$(egress_mode)" == "offline" ]] \
    || die "the lab user is not offline. As root: post-01-why-and-the-cage/00_root_setup.sh --offline, then ./04_prove_offline.sh"
# The answer key and test B's files exist (made online, by 02).
[[ -f "${ANSWER_KEY}" ]] || die "no answer key: run ./02_prepare_online.sh first (online)."

step "The drop counter, before"
before="$(drop_counter)"
[[ "${before}" =~ ^[0-9]+$ ]] || die "can't read the policy's drop counter."
printf 'DROPPED_BEFORE=%s\nAT_UTC=%s\n' "${before}" "$(date -u '+%Y-%m-%d %H:%M:%S')" > "${COUNTER_FILE}"
info "Packets dropped for ${LAB_USER} so far: ${before}"

for model in ${LOCAL_MODELS}; do
    started=${SECONDS}
    run_tests local "${model}"
    step "${model}: both tests took $(( (SECONDS - started) / 60 )) min $(( (SECONDS - started) % 60 )) s"
done

step "The drop counter, after"
after="$(drop_counter)"
info "Packets dropped for ${LAB_USER}: ${before} before, ${after} after: $(( after - before )) during the local runs."
if (( after == before )); then
    info "Nothing in the lab tried to reach the internet while the local models worked."
else
    warn "Something tried to send $(( after - before )) packet(s) out during the runs, and was stopped."
    warn "  Which process: run the tests again while watching 'ss -tunp' as ${LAB_USER}."
fi
printf 'DROPPED_AFTER=%s\nAT_UTC=%s\n' "${after}" "$(date -u '+%Y-%m-%d %H:%M:%S')" >> "${COUNTER_FILE}"
# Runs that ended with an error are results too: say how many.
(( FAILED_RUNS == 0 )) || warn "${FAILED_RUNS} run(s) ended with an error; ./06_compare.sh shows how each run ended."

step "Done"
info "Next: ./06_compare.sh (works offline too). When you're done offline, as root:"
info "  post-01-why-and-the-cage/00_root_setup.sh      (without --offline: back online)"
