#!/usr/bin/env bash
# =============================================================================
# 00_root_setup.sh
#
# The ONLY script that runs as root. Run it once, before everything else.
# Every other script in this repository runs as the lab user.
#
#   sudo ./00_root_setup.sh            set up (safe to rerun)
#   sudo ./00_root_setup.sh --offline  the same, but the lab user goes OFFLINE:
#                                      loopback only, no DNS, no internet (post 12).
#                                      Rerun without --offline to go back online.
#   sudo ./00_root_setup.sh --remove   undo everything this script did
#
# What it does (set up):
#   1. checks the OS and installs the packages the lab needs
#   2. creates the lab user (default name: oralab) with no password
#   3. enables "linger" so the lab user's containers keep running
#   4. loads the outbound network policy for the lab user (root-owned, so
#      the lab user can't loosen its own cage), and reloads it at boot.
#      Normal mode: loopback, DNS through this server's DNS servers, and
#      HTTPS to the hosts in EGRESS_ALLOWED_HOSTS only (default: OpenRouter).
#      Offline mode (--offline): loopback only. The mode is whatever the LAST
#      run of this script wrote, and it survives a reboot
#   5. installs a minimal sudoers entry: two READ-ONLY commands used by
#      03_verify.sh. Nothing that changes the system.
#   6. downloads the database image into the lab user's storage (the lab
#      user can't: its HTTPS reaches only the allowed hosts)
#   7. gives the lab user this repository WITHOUT GitHub credentials: a
#      read-only mirror in /srv/oralab, made from root's own clone, and a
#      first clone of it in the lab user's home
#
# To update the lab with new scripts from GitHub (as root):
#   git -C <root's clone> pull && sudo ./00_root_setup.sh
# then, as the lab user:  git -C ~/oracle-agentic-dba-lab pull
#
# Oracle analogy: running root.sh after an Oracle installation. A short,
# well-defined list of root actions, then everything else is done as the
# software owner.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# This is the root step.
require_root
# Read env.example and .env.
load_config

# Path of the sudoers entry (files in /etc/sudoers.d must not contain dots).
SUDOERS_FILE="/etc/sudoers.d/${LAB_USER}"
# Read-only mirror of this repository, owned by root, readable by everyone.
REPO_MIRROR="/srv/oralab/repo.git"
# The lab user's own clone of the mirror.
LAB_REPO="${LAB_HOME}/oracle-agentic-dba-lab"

# Parse the single optional argument.
# Network mode of the lab user, for step 4: online (normal) or offline.
egress_mode="online"
case "${1:-}" in
    "")        mode="setup" ;;
    --offline) mode="setup"; egress_mode="offline" ;;
    --remove)  mode="remove" ;;
    *)         die "usage: $0 [--offline | --remove]" ;;
esac

# =============================================================================
if [[ "${mode}" == "remove" ]]; then
# =============================================================================
    # Refuse to delete a user this script didn't create.
    if lab_user_exists && ! lab_user_is_ours; then
        die "user '${LAB_USER}' was not created by this lab; refusing to remove it."
    fi
    # Destructive: ask the operator to type the user name.
    read -r -p "This deletes user ${LAB_USER}, its home (all containers, images, datafiles), its sudoers entry, network policy and repository mirror. Type '${LAB_USER}' to confirm: " answer
    [[ "${answer}" == "${LAB_USER}" ]] || die "not confirmed; nothing was changed."

    step "Removing the lab user"
    if lab_user_exists; then
        # Stop the user's service manager and every process it owns
        # (this also stops its containers).
        loginctl disable-linger "${LAB_USER}"
        loginctl terminate-user "${LAB_USER}" 2>/dev/null || true
        systemctl stop "user@$(id -u "${LAB_USER}").service" 2>/dev/null || true
        pkill -KILL -u "${LAB_USER}" 2>/dev/null || true
        sleep 2
        # Delete the user and its home (container storage and password included).
        userdel --remove "${LAB_USER}"
        info "User ${LAB_USER} and ${LAB_HOME} removed."
    else
        info "User ${LAB_USER} does not exist."
    fi
    # Remove leftover subordinate ID ranges, if userdel kept them.
    sed -i "/^${LAB_USER}:/d" /etc/subuid /etc/subgid

    step "Removing the sudoers entry"
    rm -f "${SUDOERS_FILE}"
    info "${SUDOERS_FILE} removed."

    step "Removing the outbound network policy"
    # Stopping the unit deletes the nftables table; then disable it.
    systemctl disable --now --quiet "${EGRESS_UNIT}" 2>/dev/null || true
    # Delete the table directly too, in case the unit was already gone.
    nft delete table inet "${EGRESS_TABLE}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${EGRESS_UNIT}"
    rm -rf /etc/oralab
    systemctl daemon-reload
    info "Policy removed."

    step "Removing the repository mirror"
    # Delete the mirror folder.
    rm -rf /srv/oralab
    # Remove the trust entry for it from the system git configuration.
    git config --system --fixed-value --unset-all safe.directory "${REPO_MIRROR}" 2>/dev/null || true
    info "/srv/oralab removed."

    step "Done"
    info "Packages installed by this script were kept."
    exit 0
fi

# =============================================================================
# Set up
# =============================================================================

step "1/7 Operating system and packages"
# /etc/os-release describes the distribution.
# shellcheck disable=SC1091
source /etc/os-release
info "Found: ${PRETTY_NAME}"
# CentOS Stream 10 is the target; other EL10 distributions are accepted with a warning.
if [[ "${ID}" != "centos" || "${VERSION_ID%%.*}" != "10" ]]; then
    [[ " ${ID_LIKE:-} " == *" rhel "* && "${VERSION_ID%%.*}" == "10" ]] || die "CentOS Stream 10 (or another EL10) required."
    warn "Not CentOS 10, but an EL10 distribution: continuing."
fi
# Rootless containers need cgroups v2 (the EL10 default).
[[ "$(stat -fc %T /sys/fs/cgroup)" == "cgroup2fs" ]] || die "cgroups v2 is not active."
# Packages, and why each is needed:
#   podman passt container-selinux  rootless containers and their networking
#   nftables                        the outbound policy
#   iproute curl                    checks in 03_verify.sh
#   python3                         password generation and the agent harness
#   systemd-container               "machinectl shell", to log in as the lab user
#   sudo git                        the sudoers entry, and cloning the repository
#   java-21-openjdk-headless unzip  SQLcl and its MCP server (post 02): Java 17/21, zip install
dnf install -y podman passt container-selinux nftables iproute curl python3 systemd-container sudo git \
               java-21-openjdk-headless unzip
info "$(podman --version)"

step "2/7 Lab user '${LAB_USER}'"
if lab_user_exists; then
    # Never take over an account this script didn't create.
    lab_user_is_ours || die "user '${LAB_USER}' exists but was not created by this lab. Set another LAB_USER in .env."
    info "User exists."
else
    # Create the user with a home folder and the lab marker as its comment.
    # No password is set: password logins are impossible. The way in is
    # "sudo machinectl shell ${LAB_USER}@" from an administrator account.
    useradd --create-home --home-dir "${LAB_HOME}" --shell /bin/bash --comment "${LAB_MARKER}" "${LAB_USER}"
    info "User created; password login disabled."
fi
# Rootless containers need subordinate ID ranges; useradd on EL10 allocates them.
grep -q "^${LAB_USER}:" /etc/subuid || die "no range for ${LAB_USER} in /etc/subuid. Check SUB_UID_* in /etc/login.defs."
grep -q "^${LAB_USER}:" /etc/subgid || die "no range for ${LAB_USER} in /etc/subgid. Check SUB_GID_* in /etc/login.defs."

step "3/7 Linger"
# Linger keeps the lab user's service manager (and so its containers and
# runtime directory) alive without an open login session. Idempotent.
loginctl enable-linger "${LAB_USER}"
info "Enabled."

step "4/7 Outbound network policy for '${LAB_USER}'"
# Why one policy is enough: rootless containers have no network of their own
# on the host. Everything they send leaves through a user-space process
# (pasta) running as the lab user. So rules on "packets created by this user"
# cover the lab user's shell, the agent harness AND every container.
#
# Only the lab user's packets are checked: the main chain sends them to a
# chain of their own (jump); everything else passes untouched, unchecked.
# "Everything else" includes the kernel's own packets, which belong to no
# user: IPv6 neighbour discovery (IPv6's ARP), TCP resets, ICMP errors.
# (The first version had "accept every other user" as its first rule. It
# looks the same, but the kernel's packets are not "another user": that rule
# didn't match them, and the final drop took them. On a dual-stack host, the
# neighbour solicitations for the IPv6 gateway were dropped, so IPv6 stopped
# working for the whole host, root included. Found in post 12.)
#
# Rules for the lab user's packets, in order (normal mode):
#   loopback               -> allowed (agent <-> database, local models)
#   established replies    -> allowed
#   DNS                    -> allowed, to this server's DNS servers only
#   private / LAN networks -> dropped (no "database link" to the database next door)
#   allowed hosts          -> allowed on the allowed TCP ports (default: OpenRouter, 443)
#   anything else          -> dropped and counted
#
# Offline mode (--offline) keeps the first two (loopback, replies) and drops
# everything else: no DNS, no internet, no LAN. The lab keeps working on
# loopback (database, local models); nothing it does can leave the server.
# SSH keeps working, even a login as the lab user: the connection belongs to
# the SSH server, which runs as root.
[[ "${EGRESS_ALLOWED_TCP_PORTS}" =~ ^[0-9]+( [0-9]+)*$ ]] || die "EGRESS_ALLOWED_TCP_PORTS must be port numbers separated by spaces."
# Host names only: addresses never go into the settings.
[[ -z "${EGRESS_ALLOWED_HOSTS}" || "${EGRESS_ALLOWED_HOSTS}" =~ ^[A-Za-z0-9.-]+( [A-Za-z0-9.-]+)*$ ]] || die "EGRESS_ALLOWED_HOSTS must be host names separated by spaces."
[[ ! " ${EGRESS_ALLOWED_HOSTS} " =~ \ [0-9.]+\  ]] || die "EGRESS_ALLOWED_HOSTS takes host names, not addresses."
# Root-owned folder for the rule file.
install -d -m 755 -o root -g root /etc/oralab
# The addresses behind the names, resolved now, by root: the allowed hosts
# (EGRESS_ALLOWED_HOSTS) and this server's DNS servers (/etc/resolv.conf).
# Only the generated rule file holds addresses. Each list is comma-separated,
# sorted, without duplicates, and may be empty (a host without IPv6, or a DNS
# resolver on loopback, which is allowed anyway). Not needed offline.
allowed4="" allowed6="" dns4="" dns6=""
if [[ "${egress_mode}" != "offline" ]]; then
    # Every address of every allowed host (IPv6: no IPv4-mapped ones).
    v4="" v6=""
    for host in ${EGRESS_ALLOWED_HOSTS}; do
        h4="$(getent ahostsv4 "${host}" | awk '{print $1}')" || true
        h6="$(getent ahostsv6 "${host}" | awk '$1 !~ /^::ffff:/ {print $1}')" || true
        [[ -n "${h4}${h6}" ]] || die "cannot resolve ${host} (EGRESS_ALLOWED_HOSTS)."
        v4+="${h4}"$'\n'
        v6+="${h6}"$'\n'
    done
    # Sorted, unique, comma-separated.
    allowed4="$(grep -v '^$' <<< "${v4}" | sort -u | paste -sd, -)" || true
    allowed6="$(grep -v '^$' <<< "${v6}" | sort -u | paste -sd, -)" || true
    # The DNS servers, except loopback ones.
    servers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -vE '^(127\.|::1$)')" || true
    dns4="$(grep -v ':' <<< "${servers}" | grep -v '^$' | sort -u | paste -sd, -)" || true
    dns6="$(grep ':' <<< "${servers}" | sort -u | paste -sd, -)" || true
fi
# The rules after "replies", by mode. Each mode ends with a counted drop whose
# comment names the mode, so "nft list table" shows which mode is active.
if [[ "${egress_mode}" == "online" ]]; then
    # One rule per address family, only for the lists that aren't empty.
    ports="${EGRESS_ALLOWED_TCP_PORTS// /, }"
    dns_rules=""
    host_rules=""
    if [[ -n "${dns4}" ]]; then dns_rules+="        ip daddr { ${dns4} } meta l4proto { tcp, udp } th dport 53 accept"$'\n'; fi
    if [[ -n "${dns6}" ]]; then dns_rules+="        ip6 daddr { ${dns6} } meta l4proto { tcp, udp } th dport 53 accept"$'\n'; fi
    if [[ -n "${allowed4}" ]]; then host_rules+="        ip daddr { ${allowed4} } tcp dport { ${ports} } accept"$'\n'; fi
    if [[ -n "${allowed6}" ]]; then host_rules+="        ip6 daddr { ${allowed6} } tcp dport { ${ports} } accept"$'\n'; fi
    internet_rules="
        # Name resolution, through this server's DNS servers only.
${dns_rules}
        # Nothing on private, carrier-grade NAT or link-local networks (your LAN).
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
        ip6 daddr { fc00::/7, fe80::/10 } counter drop

        # The allowed hosts (${EGRESS_ALLOWED_HOSTS:-none}), on the allowed TCP ports only.
${host_rules}
        # Everything else from the lab user: dropped and counted.
        counter drop comment \"lab user: mode online\""
else
    internet_rules="
        # OFFLINE MODE (00_root_setup.sh --offline): no DNS, no internet, no LAN.
        # Everything else from the lab user: dropped and counted.
        counter drop comment \"lab user: mode offline\""
fi
# Write the rule file (always rewritten, so it always matches the settings).
# The first two lines make loading idempotent: create the table if missing,
# delete it, then define it from scratch. "nft -f" applies the whole file as
# one atomic transaction, so there is never a moment without a policy.
cat > "${EGRESS_NFT_FILE}" <<EOF
# Generated by 00_root_setup.sh (oracle-agentic-dba-lab). Do not edit: rerun the script.
# Outbound policy for lab user ${LAB_USER} (uid $(id -u "${LAB_USER}")).
table inet ${EGRESS_TABLE}
delete table inet ${EGRESS_TABLE}

table inet ${EGRESS_TABLE} {
    chain output {
        # Inspect every packet created on this host before it leaves.
        type filter hook output priority filter; policy accept;

        # Only the lab user's packets are checked (chain lab_user). Everything
        # else passes: other users (including root) and the kernel's own
        # packets, which belong to no user (IPv6 neighbour discovery, TCP
        # resets, ICMP errors).
        meta skuid $(id -u "${LAB_USER}") jump lab_user
    }

    chain lab_user {
        # Loopback: agent <-> database and local models.
        oifname "lo" accept

        # Replies within connections that were already allowed.
        ct state established,related accept
${internet_rules}
    }
}
EOF
# Root-owned and not writable by anyone else.
chown root:root "${EGRESS_NFT_FILE}"
chmod 644 "${EGRESS_NFT_FILE}"
# Check the syntax before loading.
nft -c -f "${EGRESS_NFT_FILE}" || die "invalid rules in ${EGRESS_NFT_FILE}."
# A systemd unit loads the same file at every boot, after the firewall.
cat > "/etc/systemd/system/${EGRESS_UNIT}" <<EOF
# Generated by 00_root_setup.sh (oracle-agentic-dba-lab). Do not edit: rerun the script.
[Unit]
Description=oracle-agentic-dba-lab: outbound network policy for lab user ${LAB_USER}
After=firewalld.service nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${EGRESS_NFT_FILE}
ExecStop=-/usr/sbin/nft delete table inet ${EGRESS_TABLE}

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "/etc/systemd/system/${EGRESS_UNIT}"
# Register, enable at boot, start (first run) ...
systemctl daemon-reload
systemctl enable --quiet "${EGRESS_UNIT}"
systemctl start "${EGRESS_UNIT}"
# ... and load the current file now, so a rerun always applies the latest rules.
nft -f "${EGRESS_NFT_FILE}"
if [[ "${egress_mode}" == "online" ]]; then
    info "Policy active (online): loopback, DNS through this server's DNS servers, TCP ${EGRESS_ALLOWED_TCP_PORTS} to ${EGRESS_ALLOWED_HOSTS:-no host} only. Nothing on the LAN."
else
    warn "Policy active (OFFLINE): loopback only. No DNS, no internet, no LAN for ${LAB_USER}."
    info "To go back online: rerun $0 without --offline."
fi

step "5/7 Sudoers entry for '${LAB_USER}'"
# Exactly two commands, both read-only, both with fixed arguments, used by
# 03_verify.sh to prove the isolation:
#   - list the lab's nftables table (reading the firewall needs root)
#   - list the firewalld zones (to prove no zone opens the database port)
# No shell, no wildcards, nothing that changes the system.
# Oracle analogy: a GRANT of SELECT on two dictionary views, not DBA.
tmp="$(mktemp)"
cat > "${tmp}" <<EOF
# Generated by 00_root_setup.sh (oracle-agentic-dba-lab). Do not edit: rerun the script.
# Read-only commands used by 03_verify.sh.
${LAB_USER} ALL=(root) NOPASSWD: /usr/sbin/nft list table inet ${EGRESS_TABLE}, /usr/bin/firewall-cmd --list-all-zones
EOF
# Validate with visudo before installing: a broken sudoers file can lock out sudo.
visudo -cqf "${tmp}" || { rm -f "${tmp}"; die "generated sudoers entry is invalid."; }
# Install with the mode sudo requires (0440, root-owned).
install -m 440 -o root -g root "${tmp}" "${SUDOERS_FILE}"
rm -f "${tmp}"
info "${SUDOERS_FILE} installed (2 read-only commands)."

step "6/7 Database image for '${LAB_USER}'"
# The lab user's HTTPS reaches only the allowed hosts, so it can't download
# the database image (pinned by digest, see env.example) itself. Root pulls
# it AS the lab user, into the lab user's own storage, during a short
# download window: the same rules plus HTTPS to any internet host (the
# registry's addresses rotate, and its files come from a cloud storage
# service). The real policy comes back right after, even if the pull fails.
# A command as the lab user: from /, with its home and its runtime directory.
as_lab_user() {
    (cd / && runuser -u "${LAB_USER}" -- env HOME="${LAB_HOME}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "${LAB_USER}")" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "${LAB_USER}")/bus" "$@")
}
if as_lab_user podman image exists "${DB_IMAGE}"; then
    info "${LAB_USER} has the image already."
else
    # Offline mode allows no download at all.
    [[ "${egress_mode}" == "online" ]] || die "${LAB_USER} has no database image, and offline mode allows no download. Run $0 without --offline first."
    # Whatever happens from here, the real policy is loaded again at exit.
    trap 'nft -f "${EGRESS_NFT_FILE}"' EXIT
    # The download window: HTTPS to any host, inserted before the final drop.
    sed 's/^\( *\)counter drop comment "lab user: mode online"$/\1tcp dport 443 accept comment "download window"\n&/' "${EGRESS_NFT_FILE}" | nft -f -
    info "Pulling ${DB_IMAGE} as ${LAB_USER} (several GB, first time only)..."
    as_lab_user podman pull --quiet "${DB_IMAGE}" >/dev/null
    # Window closed: the real policy again.
    nft -f "${EGRESS_NFT_FILE}"
    trap - EXIT
    info "Image ready; the download window is closed."
fi

step "7/7 Repository for '${LAB_USER}' (no GitHub credentials)"
# Why: the lab user must never hold GitHub credentials, because later in the
# series an AI agent runs as that user and could read them, and it must be
# able to update its scripts without the network (offline mode). So root, which already has a clone (the one this
# script is running from), keeps a read-only mirror of it on this server,
# and the lab user clones and pulls from that mirror: no network, no secrets.
# Oracle analogy: giving a team a read-only copy of a schema instead of the
# production password.

# Root's clone: the repository this script lives in.
ROOT_REPO="$(git -C "${POST01_DIR}" rev-parse --show-toplevel 2>/dev/null)" \
    || die "${POST01_DIR} is not inside a git clone. Run this script from a clone of the repository."
# Root-owned folder for the mirror.
install -d -m 755 -o root -g root /srv/oralab
if [[ -d "${REPO_MIRROR}" ]]; then
    # Mirror exists: bring it up to date with root's clone. Its "origin" is
    # root's clone, and --prune drops branches that were deleted there.
    git -C "${REPO_MIRROR}" fetch --quiet --prune origin
    info "Mirror refreshed from ${ROOT_REPO}."
else
    # First run: create a bare mirror of root's clone.
    git clone --quiet --mirror "${ROOT_REPO}" "${REPO_MIRROR}"
    info "Mirror created from ${ROOT_REPO}."
fi
# Owned by root, readable by everyone, writable by nobody else: the lab user
# can read it but cannot change what root publishes.
chown -R root:root "${REPO_MIRROR}"
chmod -R u+rwX,go+rX,go-w "${REPO_MIRROR}"
# Git refuses to read a repository owned by another user ("dubious
# ownership") unless it is explicitly trusted. Trust exactly this one path,
# system-wide, once.
if ! git config --system --get-all safe.directory 2>/dev/null | grep -qxF "${REPO_MIRROR}"; then
    git config --system --add safe.directory "${REPO_MIRROR}"
fi
info "Mirror ${REPO_MIRROR}: read-only for ${LAB_USER}."

# First clone for the lab user, only if it doesn't have one yet. An existing
# clone is never touched: it may hold local settings (.env files).
if [[ -d "${LAB_REPO}/.git" ]]; then
    info "${LAB_REPO} exists; update it as ${LAB_USER} with: git -C ${LAB_REPO} pull"
else
    # Clone as the lab user (so it owns the files), with its own HOME and a
    # readable working directory.
    (cd / && runuser -u "${LAB_USER}" -- env HOME="${LAB_HOME}" git clone --quiet "${REPO_MIRROR}" "${LAB_REPO}")
    info "Cloned into ${LAB_REPO}."
fi

step "Root setup complete"
info "Everything else runs as ${LAB_USER}. Next:"
info "  sudo machinectl shell ${LAB_USER}@"
info "  cd ~/oracle-agentic-dba-lab/post-01-why-and-the-cage"
info "  ./01_prereqs.sh && ./02_build.sh && ./03_verify.sh"
info "To update later: as root, git -C ${ROOT_REPO} pull && $0 ; as ${LAB_USER}, git -C ~/oracle-agentic-dba-lab pull"
