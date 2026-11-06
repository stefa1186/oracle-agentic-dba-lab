#!/usr/bin/env bash
# =============================================================================
# 01_prereqs.sh
#
# Checks, as the lab user, that the server is ready for the lab: the root
# setup was done, the tools are installed, and there are enough resources.
# Changes nothing. Safe to run any number of times.
#
# Run as the lab user (after "sudo ./00_root_setup.sh"):
#   sudo machinectl shell oralab@
#   ./01_prereqs.sh
#
# Oracle analogy: the installer's prerequisite checks, run as the software
# owner before anything is created.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read env.example and .env.
load_config
# Must be the lab user, in a proper login session.
require_lab_user

step "Root setup (00_root_setup.sh)"
# The user carries the lab marker, i.e. it was created by the root step.
lab_user_is_ours || die "${LAB_USER} was not created by 00_root_setup.sh."
info "Lab user: ${LAB_USER}"
# Linger keeps containers running after logout.
loginctl show-user "${LAB_USER}" --property=Linger | grep -q 'Linger=yes' || die "linger is off. Run: sudo ./00_root_setup.sh"
info "Linger: on"
# The outbound policy unit is active.
systemctl is-active --quiet "${EGRESS_UNIT}" || die "${EGRESS_UNIT} is not active. Run: sudo ./00_root_setup.sh"
info "Outbound policy: active"
# Subordinate ID ranges exist (needed by rootless containers).
grep -q "^${LAB_USER}:" /etc/subuid || die "no subuid range for ${LAB_USER}. Run: sudo ./00_root_setup.sh"
info "Subordinate IDs: present"

step "Tools"
# Every command the lab scripts and the agent harness use.
for cmd in podman curl python3 ss git; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} not found. Run: sudo ./00_root_setup.sh"
done
info "$(podman --version)"
# Rootless Podman works for this user (also creates its storage on first use).
podman info --format '{{.Host.Security.Rootless}}' | grep -q true || die "podman is not running rootless for ${LAB_USER}."
info "Rootless Podman: OK"

step "Resources"
# Total memory in GiB, from /proc/meminfo (value in kB).
mem_gb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
info "Memory: ${mem_gb} GiB"
# The database needs ~4 GiB; local models in later posts need more.
(( mem_gb >= 8 )) || warn "Less than 8 GiB of RAM. The database will run, but local models will struggle."
# Free space in the home folder, where container images and datafiles live.
free_gb=$(( $(df --output=avail -k "${HOME}" | tail -1) / 1024 / 1024 ))
info "Free space in ${HOME}: ${free_gb} GiB"
# The image and datafiles need ~20 GiB; local models need more.
(( free_gb >= 30 )) || warn "Less than 30 GiB free. The image and datafiles need ~20 GiB."

step "Ready"
info "Next: ./02_build.sh"
