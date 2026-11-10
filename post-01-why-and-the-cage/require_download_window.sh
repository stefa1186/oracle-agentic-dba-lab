#!/usr/bin/env bash
# =============================================================================
# require_download_window.sh
#
# Stops a download script unless root has opened a download window for the
# lab user. The lab user's HTTPS reaches only the allowed hosts (env.example,
# default: OpenRouter), so downloads from anywhere else need that window:
#   sudo ./00_root_setup.sh --download-window [minutes]
#
# Run by the download scripts of later posts, as the lab user. Exit code 0 if
# the window is open, 1 (with the command to run) if it isn't.
# Oracle analogy: a job that checks its maintenance window before it starts.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings (EGRESS_TABLE, EGRESS_ALLOWED_HOSTS).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read env.example and .env.
load_config

# The loaded policy, read with the lab user's read-only sudo command: an open
# window is a rule with the comment "download window".
if sudo -n /usr/sbin/nft list table inet "${EGRESS_TABLE}" 2>/dev/null | grep -q 'download window'; then
    info "Download window: open."
    exit 0
fi
# Closed: say what to do, and stop the calling script.
die "this step downloads from the internet, and ${LAB_USER} may reach only ${EGRESS_ALLOWED_HOSTS:-no host}.
Ask root for a download window, then rerun this script:
    sudo /root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh --download-window"
