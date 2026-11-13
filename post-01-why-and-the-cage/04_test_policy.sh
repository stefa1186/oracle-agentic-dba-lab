#!/usr/bin/env bash
# =============================================================================
# 04_test_policy.sh
#
# Tests the outbound policy's RULES, not this host: in a throwaway network,
# built and destroyed by this script, with no root and no change to the host.
#
#   ./04_test_policy.sh                  this repository's 00_root_setup.sh
#   ./04_test_policy.sh <setup script>   another version of it, e.g. an old copy:
#       ./04_test_policy.sh /path/to/old/00_root_setup.sh
#
# How: "unshare" gives this script its own user and network namespace (an
# empty network stack of its own, like a private PDB with no listener). In it:
#   - a virtual cable (veth) to a second, private namespace "B"
#   - in B, two listeners: [2001:db8::2]:443 and :80 (documentation addresses)
#   - in this namespace, a third one on loopback: [::1]:5555
# Then each rule file is loaded here, and three connections are tried: 443,
# 80 and loopback. IPv6 on purpose: a connection over IPv6 first needs
# neighbour discovery (IPv6's ARP), packets the kernel sends itself, which
# belong to no user. A rule set that drops them breaks IPv6 for everyone.
#
# The rule files tested:
#   1. online and offline, written by 00_root_setup.sh (its own code, run
#      with a fake "id"), once for "the lab user" (the uid this script has
#      in the namespace) and once for "another user"
#   2. the file this host has loaded now (/etc/oralab/egress.nft), rewritten
#      for "another user": a policy that breaks IPv6 for other users fails
#      here (the first version of the policy did, for the whole host)
#
# Expected, and checked:
#                         443      80       loopback
#   lab user, online      works    blocked  works
#   lab user, offline     blocked  blocked  works
#   another user          works    works    works      (not the lab's business)
#
# Run as the lab user. Changes nothing outside its own namespaces.
# Needs: unshare, nsenter, ip, nft, python3 (all on the lab since post 01).
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings (EGRESS_TABLE, EGRESS_NFT_FILE, ...).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read env.example and .env.
load_config
# Must be the lab user.
require_lab_user

# The setup script whose rules are tested: this repository's, or the one given.
setup_script="${1:-${POST01_DIR}/00_root_setup.sh}"
[[ -r "${setup_script}" ]] || die "cannot read ${setup_script}."

# Every tool this test needs (nft is in /usr/sbin, often not in PATH).
NFT=/usr/sbin/nft
for tool in unshare nsenter ip python3 "${NFT}"; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found."
done

# A private working folder for the generated rule files, removed at the end.
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

step "1/2 The rule files"
# The rule-writing block of 00_root_setup.sh: from "if online" to the end of
# its rule file (the first line that is only EOF). The test runs the
# script's own code, so it tests what root really loads.
awk '/^if \[\[ "\$\{egress_mode\}" == "online" \]\]; then$/ { on = 1 }
     on { print }
     on && /^EOF$/ { exit }' "${setup_script}" > "${work}/block.sh"
grep -q '^EOF$' "${work}/block.sh" || die "could not find the rule file block in ${setup_script}."
# In the namespace this script is uid 0: rules for uid 0 test "the lab user";
# rules for uid 4242 (nobody here) test "another user".
for uid in 0 4242; do
    for mode in online offline; do
        # A subshell, so the block's variables and the fake id stay inside it.
        # The block also reads LAB_USER, EGRESS_TABLE and
        # EGRESS_ALLOWED_TCP_PORTS, already set by lib.sh and load_config.
        # shellcheck disable=SC2030,SC2329
        (
            # The block asks "id -u <lab user>" for the uid: answer the test's.
            id() { echo "${uid}"; }
            # The mode, as 00_root_setup.sh would set it from its argument.
            egress_mode="${mode}"
            # Where the block writes the rule file (a test file, not /etc).
            EGRESS_NFT_FILE="${work}/${mode}_${uid}.nft"
            # shellcheck disable=SC1091
            source "${work}/block.sh"
        )
    done
done
# The file loaded on this host now (readable by everyone), for "another user":
# its uid, in either rule form (old: "skuid != N", new: "skuid N").
# (The subshells above changed nothing out here: these are the real values.)
# shellcheck disable=SC2031
real_uid="$(id -u "${LAB_USER}")"
sed -E "s/meta skuid (!= )?${real_uid} /meta skuid \\14242 /" "${EGRESS_NFT_FILE}" > "${work}/loaded_4242.nft"
info "Written by ${setup_script}: online and offline, for the lab user and for another user."
info "Loaded on this host: ${EGRESS_NFT_FILE}, for another user."

step "2/2 Three connections per rule file, in a throwaway network"
# Everything from here runs in a new user + network namespace: "-r" maps this
# user to root INSIDE it only (enough to build a network there, nothing else).
export work NFT EGRESS_TABLE
rc=0
unshare -rn bash -s <<'NS' || rc=$?
# Stop on errors, unset variables and pipeline failures, inside too.
set -euo pipefail
# Loopback up: it starts down in a new namespace.
ip link set lo up
# Namespace B: a sleeping process keeps it alive (it ends with this test).
unshare -n sleep 300 < /dev/null & pid_b=$!
sleep 0.5
# The virtual cable: one end here (va), the other end in B (vb).
ip link add va type veth peer name vb
ip link set vb netns "${pid_b}"
# Addresses from the IPv6 documentation range, without duplicate detection
# (nodad: usable at once). Not a LAN range, so the LAN rule doesn't apply.
ip addr add 2001:db8::1/64 dev va nodad
ip link set va up
nsenter -t "${pid_b}" -n ip link set lo up
nsenter -t "${pid_b}" -n ip addr add 2001:db8::2/64 dev vb nodad
nsenter -t "${pid_b}" -n ip link set vb up
# A listener that accepts and closes every connection, forever. Background
# processes get stdin from /dev/null: this script itself is read from stdin.
listen() {
    exec python3 -c '
import socket, sys
# One IPv6 TCP socket on the given address and port.
s = socket.socket(socket.AF_INET6)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen()
# Accept and close: a successful connect is all the test needs.
while True:
    c, _ = s.accept()
    c.close()
' "$1" "$2"
}
export -f listen
# Two listeners in B, one on this namespace's loopback.
nsenter -t "${pid_b}" -n bash -c "listen 2001:db8::2 443" < /dev/null & pid_443=$!
nsenter -t "${pid_b}" -n bash -c "listen 2001:db8::2 80" < /dev/null & pid_80=$!
listen ::1 5555 < /dev/null & pid_lo=$!
sleep 1
# One connection attempt: "works" or "blocked" (4 seconds at most).
try() {
    if timeout 4 bash -c "</dev/tcp/$1/$2" 2>/dev/null; then echo works; else echo blocked; fi
}
# The expected results, per rule file: 443 80 loopback.
declare -A want=(
    [online_0]="works blocked works"
    [offline_0]="blocked blocked works"
    [online_4242]="works works works"
    [offline_4242]="works works works"
    [loaded_4242]="works works works"
)
# Readable names for the rule files.
declare -A label=(
    [online_0]="online,  lab user"
    [offline_0]="offline, lab user"
    [online_4242]="online,  another user"
    [offline_4242]="offline, another user"
    [loaded_4242]="loaded,  another user"
)
failed=0
printf '    %-23s %-8s %-8s %-9s %s\n' "RULES" "443" "80" "LOOPBACK" "RESULT"
for f in online_0 offline_0 online_4242 offline_4242 loaded_4242; do
    # Load this rule file alone.
    "${NFT}" flush ruleset
    "${NFT}" -f "${work}/${f}.nft"
    # Forget B's link-layer address, so the kernel must ask for it again.
    ip -6 neigh del 2001:db8::2 dev va 2>/dev/null || true
    got="$(try 2001:db8::2 443) $(try 2001:db8::2 80) $(try ::1 5555)"
    if [[ "${got}" == "${want[${f}]}" ]]; then result="PASS"; else result="FAIL (expected: ${want[${f}]})"; failed=1; fi
    read -r r443 r80 rlo <<< "${got}"
    printf '    %-23s %-8s %-8s %-9s %s\n' "${label[${f}]}" "${r443}" "${r80}" "${rlo}" "${result}"
done
# Stop the listeners and namespace B.
kill "${pid_443}" "${pid_80}" "${pid_lo}" "${pid_b}" 2>/dev/null || true
wait 2>/dev/null || true
exit "${failed}"
NS

step "Done"
if (( rc == 0 )); then
    info "Every rule file behaves as expected. Nothing outside this test's namespaces was touched."
else
    die "at least one rule file did not behave as expected (see above)."
fi
