#!/usr/bin/env bash
# =============================================================================
# incident_session.sh  (started by 02_create_incident.sh, not by hand)
#
# Runs ONE incident session file as the application user. The password is
# the first line of stdin, so it never appears on a command line (ps would
# show it there); it goes on to SQL*Plus through stdin as well.
#
# Usage: printf '%s\n' "<password>" | incident_session.sh <session_file.sql> [<then_file.sql>]
#
# With <then_file.sql>, the session is HELD: after the first file SQL*Plus
# gets nothing for INCIDENT_MINUTES, then the second file. Meanwhile the
# session is idle, with its transaction open (run_post10_session_held).
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-10 settings.
load_post10_config

# The session file to run (a file name in this folder), and optionally the
# file to send when the hold is over.
[[ $# -eq 1 || $# -eq 2 ]] || die "usage: printf '%s\\n' <password> | $0 <session_file.sql> [<then_file.sql>]"
# The password: first line of stdin.
IFS= read -r shop_pwd || die "no password on stdin."
# Run it; the session logs to this script's stdout/stderr (redirected by the caller).
if [[ $# -eq 2 ]]; then
    # Held: the second file only after INCIDENT_MINUTES.
    run_post10_session_held "$1" "$2" "$(( INCIDENT_MINUTES * 60 ))" "define shop_pwd = ${shop_pwd}"
else
    run_post10_session "$1" "define shop_pwd = ${shop_pwd}"
fi
