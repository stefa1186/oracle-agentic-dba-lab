#!/usr/bin/env bash
# =============================================================================
# 03_verify.sh
#
# Proves the lab is up AND isolated, with one PASS/FAIL line per check.
# Changes nothing, so it can be run at any time, any number of times.
# Exit code: 0 if every check passes, 1 otherwise.
#
# Run as the lab user. Two checks read the firewall, which needs root: they
# use the two read-only sudo commands installed by 00_root_setup.sh. One more
# check proves those two commands are ALL the lab user can run with sudo.
#
# Oracle analogy: a post-installation health check, plus a security audit of
# what the lab can and cannot reach.
# =============================================================================

# Stop on unset variables and pipeline failures. Not -e: a failed check must
# be reported, not stop the script.
set -uo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read env.example and .env.
load_config
# Must be the lab user, in a proper login session.
require_lab_user

# Counters for the final summary.
passed=0
failed=0

# check "<description>" <command...>: PASS if the command succeeds.
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "${desc}"
        passed=$((passed + 1))
    else
        printf '  FAIL  %s\n' "${desc}"
        failed=$((failed + 1))
    fi
}

# check_blocked "<description>" <command...>: PASS if the command FAILS
# (used for "this must be unreachable").
check_blocked() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '  FAIL  %s\n' "${desc}"
        failed=$((failed + 1))
    else
        printf '  PASS  %s\n' "${desc}"
        passed=$((passed + 1))
    fi
}

# check_dropped "<description>" <command...>: PASS only if the command timed
# out (exit code 124 from "timeout"): the policy dropped the packets. Any other
# failure (unknown host, connection refused, container not running) is a FAIL:
# a check that could not look must never be reported as PASS.
check_dropped() {
    local desc="$1"
    shift
    "$@" >/dev/null 2>&1
    if [[ $? -eq 124 ]]; then
        printf '  PASS  %s\n' "${desc}"
        passed=$((passed + 1))
    else
        printf '  FAIL  %s\n' "${desc}"
        failed=$((failed + 1))
    fi
}

# The internet hosts the outbound checks use: the first allowed host (the lab
# user must reach it on 443), another web server and a public DNS service
# (the lab user must reach neither).
allowed_host="${EGRESS_ALLOWED_HOSTS%% *}"
other_host="container-registry.oracle.com"
other_dns="dns.google"

# Small predicates used by the checks below.
container_is_running() { [[ "$(container_state)" == "running" ]]; }
pdb_is_open()          { [[ "$(pdb_open_mode)" == "READWRITE" ]]; }
password_file_private() { [[ "$(stat -c %a "${DB_PASSWORD_FILE}")" == "600" ]]; }
linger_on()            { loginctl show-user "${LAB_USER}" --property=Linger | grep -q 'Linger=yes'; }
# True if every listening socket on the database port is on a loopback address.
port_on_loopback_only() {
    local addrs
    addrs="$(ss -Hltn "sport = :${DB_PORT}" | awk '{print $4}')"
    [[ -n "${addrs}" ]] && ! grep -vqE '^(127\.0\.0\.1|\[::1\]):' <<< "${addrs}"
}
# True if the database port answers on none of the server's own IPv4
# addresses, and at least one was tried. The addresses aren't printed.
port_closed_on_own_addresses() {
    local ip tried=0
    for ip in $(hostname -I); do
        # IPv6 addresses are skipped: the listener is on IPv4 loopback only.
        [[ "${ip}" == *:* ]] && continue
        tried=$((tried + 1))
        timeout 5 bash -c "</dev/tcp/${ip}/${DB_PORT}" 2>/dev/null && return 1
    done
    (( tried > 0 ))
}
# True if the firewalld zones could be read (via sudo) AND none of them opens
# the database port. If the zones can't be read, this is false: a check that
# could not look must never be reported as PASS.
firewalld_keeps_port_closed() {
    local zones
    # Read every zone with the read-only sudo command; stop if that fails.
    zones="$(sudo -n /usr/bin/firewall-cmd --list-all-zones 2>/dev/null)" || return 1
    # The port must not appear in any zone.
    ! grep -qE "\\b${DB_PORT}/tcp" <<< "${zones}"
}
# The commands the lab user may run with sudo, one per line, sorted.
# "sudo -n -l" lists them (-n: never prompt for a password). The text after
# "may run the following commands" looks like:
#     (root) NOPASSWD: /usr/sbin/nft list table inet ..., /usr/bin/firewall-cmd ...
# In a terminal, sudo wraps long lines at the screen width, so the parsing
# must not depend on line breaks: join everything into one line, turn every
# "(runas) TAG: TAG:" marker into a comma, split on commas, squeeze spaces, sort.
sudo_commands() {
    sudo -n -l 2>/dev/null \
        | awk '/may run the following commands/ { found = 1; next } found' \
        | tr '\n' ' ' \
        | sed -E 's/\([^)]*\)[[:space:]]*([A-Z_]+:[[:space:]]*)*/,/g' \
        | tr ',' '\n' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
        | grep -v '^$' \
        | sort
}
# The two read-only commands 00_root_setup.sh installs, sorted the same way.
expected_sudo_commands() {
    printf '%s\n' "/usr/bin/firewall-cmd --list-all-zones" "/usr/sbin/nft list table inet ${EGRESS_TABLE}" | sort
}
# True if the lab user can run exactly those two commands with sudo, nothing else.
# Oracle analogy: reading DBA_SYS_PRIVS for a user, not just testing one grant.
sudo_is_read_only() { [[ "$(sudo_commands)" == "$(expected_sudo_commands)" ]]; }

# -----------------------------------------------------------------------------
step "Lab user"
# -----------------------------------------------------------------------------
check "user ${LAB_USER} was created by the root setup" lab_user_is_ours
check "linger is enabled" linger_on
check "password file is private (mode 600)" password_file_private

# -----------------------------------------------------------------------------
step "Database"
# -----------------------------------------------------------------------------
check "container ${DB_CONTAINER} is running" container_is_running
check "FREEPDB1 is open READ WRITE" pdb_is_open
# Show the version banner (information, not a check).
banner="$(db_sqlplus <<'SQL' 2>/dev/null
set heading off feedback off pagesize 0 linesize 200
select banner_full from v$version;
exit
SQL
)"
info "Version: $(head -1 <<< "${banner}")"

# -----------------------------------------------------------------------------
step "Inbound isolation (who can reach the database)"
# -----------------------------------------------------------------------------
check "port ${DB_PORT} answers on 127.0.0.1" timeout 5 bash -c "</dev/tcp/127.0.0.1/${DB_PORT}"
check "port ${DB_PORT} is bound to loopback only" port_on_loopback_only
# Not reachable through any of the server's own IPv4 addresses.
check "port ${DB_PORT} is NOT reachable on the server's own addresses" port_closed_on_own_addresses
# If firewalld runs, no zone opens the port.
if systemctl is-active --quiet firewalld; then
    check "no firewalld zone opens port ${DB_PORT}" firewalld_keeps_port_closed
fi

# -----------------------------------------------------------------------------
step "Outbound isolation (what the lab can reach)"
# -----------------------------------------------------------------------------
check "outbound policy is loaded" sudo -n /usr/sbin/nft list table inet "${EGRESS_TABLE}"
check "outbound policy loads at boot" systemctl is-enabled --quiet "${EGRESS_UNIT}"
if [[ -n "${allowed_host}" ]]; then
    # HTTPS to an allowed host works (OpenRouter: the models' API).
    check "lab user CAN reach ${allowed_host} on 443" curl -sS -o /dev/null --max-time 15 "https://${allowed_host}"
    # The same over IPv6, if this host has IPv6: the policy must not break it.
    # (A first version of the policy dropped the kernel's IPv6 neighbour
    # discovery, and with it IPv6 for the whole host. Found in post 12.)
    if [[ -n "$(ip -6 route show default 2>/dev/null)" ]]; then
        check "lab user CAN reach ${allowed_host} on 443 over IPv6" curl -6 -sS -o /dev/null --max-time 15 "https://${allowed_host}"
    else
        info "No IPv6 default route on this host; IPv6 check skipped."
    fi
    # Any other port is dropped, even to an allowed host.
    check_dropped "lab user can NOT reach ${allowed_host} on port 80" timeout 5 bash -c "</dev/tcp/${allowed_host}/80"
else
    info "EGRESS_ALLOWED_HOSTS is empty: no allowed host to test."
fi
# Any other host is dropped, even on 443.
check_dropped "lab user can NOT reach other hosts (${other_host}:443)" timeout 5 bash -c "</dev/tcp/${other_host}/443"
# DNS goes only to this server's DNS servers: a public DNS service is dropped.
check_dropped "lab user can NOT reach other DNS servers (${other_dns}:53)" timeout 5 bash -c "</dev/tcp/${other_dns}/53"
# The LAN is unreachable even on an allowed port: test the default gateway.
gateway="$(ip -4 route show default | awk '{print $3; exit}')"
if [[ "${gateway}" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    check_dropped "lab user can NOT reach the LAN (its default gateway, on 443)" timeout 5 bash -c "</dev/tcp/${gateway}/443"
else
    info "Default gateway is not a private address; LAN check skipped."
fi
# The same policy applies inside the database container (it must be running).
check_dropped "database container can NOT reach other hosts (${other_host}:443)" \
    podman exec "${DB_CONTAINER}" timeout 5 bash -c "</dev/tcp/${other_host}/443"
# The lab user cannot change its own cage: the rule file is root-owned.
check_blocked "lab user can NOT modify the outbound policy file" test -w "${EGRESS_NFT_FILE}"
# ... and cannot become root to change it: its sudo rights are the two
# read-only commands above, nothing more.
check "lab user can run ONLY the 2 read-only commands with sudo" sudo_is_read_only
# If not, show what else it can run (any wider grant breaks the cage).
if ! sudo_is_read_only; then
    # comm -23: lines only in the first list = commands beyond the two expected.
    while IFS= read -r extra; do
        [[ -n "${extra}" ]] && info "Extra sudo right: ${extra}"
    done < <(comm -23 <(sudo_commands) <(expected_sudo_commands))
fi

# -----------------------------------------------------------------------------
step "Summary"
# -----------------------------------------------------------------------------
info "${passed} passed, ${failed} failed."
# Exit 1 if anything failed.
(( failed == 0 ))
