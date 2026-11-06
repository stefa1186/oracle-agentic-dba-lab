#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Returns the lab to its post 04 state:
#   1. post 08's runbook schema (RAG_LAB, its model and table), with post
#      08's own cleanup
#   2. the agent's role back to post 03, SQL Firewall back to enforcing
#   3. the local model server's container removed. The downloaded models are
#      KEPT (they are large) unless --purge-models is given
#   4. a check of the network mode: going back online needs root, so this
#      script can only remind you
# The evidence (runs, answer key, comparison) is kept.
#
#   ./99_cleanup.sh [--yes] [--purge-models]
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
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

# Options, in any order.
yes=0
purge=0
for arg in "$@"; do
    case "${arg}" in
        --yes)          yes=1 ;;
        --purge-models) purge=1 ;;
        *)              die "usage: $0 [--yes] [--purge-models]" ;;
    esac
done
# Confirmation, unless --yes.
if (( ! yes )); then
    read -r -p "This drops post 08's RAG_LAB, puts ${AGENT_DB_USER} back to post 03 with the firewall enforcing, and removes the Ollama container$( (( purge )) && echo ' AND the downloaded models'). Type 'cleanup' to confirm: " answer
    [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed."
fi

step "1/4 Post 08's runbook schema"
"${POST08_DIR}/99_cleanup.sh" --yes

step "2/4 The agent's role back to post 03, SQL Firewall back to enforcing"
env -u EXTRA_VIEW_FILES "${POST03_DIR}/01_least_privilege.sh" | grep -E 'SELECT on|AI_AGENT:' | sed 's/^/    /'
"${POST03_DIR}/04_sql_firewall.sh" enforce | grep -A4 '=== Allow-list' | sed 's/^/    /'

step "3/4 The local model server"
if (( purge )); then
    "${OLLAMA_DIR}/99_remove_ollama.sh" --purge | sed 's/^/    /'
else
    "${OLLAMA_DIR}/99_remove_ollama.sh" | sed 's/^/    /'
    # The line above names that script's own option (--purge); this one names
    # this script's option, which calls it with --purge.
    info "From here: ./99_cleanup.sh --purge-models deletes them."
fi

step "4/4 Network mode of ${LAB_USER}"
mode="$(egress_mode)"
info "Mode: ${mode}"
if [[ "${mode}" == "offline" ]]; then
    warn "${LAB_USER} is still OFFLINE. To go back online, as root:"
    warn "  post-01-why-and-the-cage/00_root_setup.sh      (without --offline)"
fi

step "Done"
info "Evidence kept in ${POST12_OUT}."
