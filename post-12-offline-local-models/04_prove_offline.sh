#!/usr/bin/env bash
# =============================================================================
# 04_prove_offline.sh
#
# Proves that the lab user is OFFLINE, and that the lab still works:
#   1. the policy: read with post 01's read-only sudo rule. Its last rule
#      must say "mode offline" (written by 00_root_setup.sh --offline)
#   2. the internet, as the lab user: HTTPS to OpenRouter by name, and HTTPS
#      to an IP address (no DNS needed). Both must FAIL. A DNS lookup is
#      tested and reported too: it fails, unless the server's resolver runs
#      on the server itself (then it answers for the lab user, as another
#      user, but no connection can follow)
#   3. the lab, on loopback: the database, and the local model server with
#      its pinned models, each one answering a fixed request (with its
#      writing speed). Both must WORK
#   4. the policy's drop counter: every packet the lab user tried to send out
#
# Oracle analogy: a database with its network cable pulled, still serving
# local connections through the bequeath protocol, no listener needed.
#
# Run as the lab user, after "00_root_setup.sh --offline" (as root). Read-only.
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

step "1/4 The lab user's network policy (root-owned, read with sudo)"
# The rules as nftables has them loaded right now.
sudo -n /usr/sbin/nft list table inet "${EGRESS_TABLE}" | sed 's/^/    /'
mode="$(egress_mode)"
info "Mode: ${mode}"
[[ "${mode}" == "offline" ]] \
    || die "the lab user is not offline. As root: post-01-why-and-the-cage/00_root_setup.sh --offline"

step "2/4 Can the lab user reach the internet? (each test must FAIL)"
failed_ok=0
# Run one test that must fail; show its own error message.
# Usage: must_fail "<label>" <command...>
must_fail() {
    local label="$1" out
    shift
    if out="$("$@" 2>&1)"; then
        warn "${label}: it WORKED. The lab user is NOT offline."
    else
        info "${label}: failed, as it must."
        # The command's own last message line, if it printed one.
        [[ -n "${out}" ]] && info "  $(tail -1 <<< "${out}")"
        failed_ok=$(( failed_ok + 1 ))
    fi
}
# The resolver(s) this server uses, from /etc/resolv.conf.
resolvers="$(awk '/^nameserver/ { printf "%s ", $2 }' /etc/resolv.conf)"
info "Resolvers in /etc/resolv.conf: ${resolvers:-none}"
# DNS: reported, not required (see the header).
if dns="$(timeout 10 getent hosts openrouter.ai 2>&1)"; then
    warn "DNS lookup of openrouter.ai: it answered (${dns%% *}). Your resolver runs on this server (${resolvers}),"
    warn "  as another user. Names resolve; connections can't follow (the two tests below)."
else
    info "DNS lookup of openrouter.ai     : failed, as it must."
fi
must_fail "HTTPS to openrouter.ai          " curl -sS -o /dev/null --max-time 10 https://openrouter.ai/api/v1/models
must_fail "HTTPS to 1.1.1.1 (no DNS needed)" curl -sS -o /dev/null --max-time 10 https://1.1.1.1/
(( failed_ok == 2 )) || die "the lab user can still reach the internet."

step "3/4 Does the lab still work on loopback? (each test must WORK)"
# The database: the usual check, then one query through the container.
require_database
info "Database: $(db_sqlplus <<'SQL' | tr -s ' ' | grep -m1 'OPEN'
set heading off feedback off pagesize 0
select instance_name || ' ' || status || ' ' || version_full from v$instance;
exit
SQL
)"
# The model server, and the exact models it holds.
info "Ollama:   version $(ollama_get /api/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
for tag in ${LOCAL_MODELS}; do
    have="$(local_digest "${tag}")"
    [[ "${have#sha256:}" == "$(pin_digest "${tag}")" ]] || die "${tag} is not on the local server with its pinned digest."
    info "Model:    ${tag}  ${have#sha256:}"
    # Listed is not enough: the model must run, here, now (probe_model in lib.sh).
    info "          asked: \"${PROBE_PROMPT}\""
    probe_model "${tag}" | sed 's/^/              /' \
        || die "${tag} is listed, but did not answer."
done

step "4/4 The drop counter"
info "Packets the policy has dropped for ${LAB_USER} so far: $(drop_counter)"
info "(It includes the tests above. ./05_run_local.sh reads it again before and after its runs.)"

step "Done"
info "The lab user is offline; the database and the local models work."
info "Next: ./05_run_local.sh"
