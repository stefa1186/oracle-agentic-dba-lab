#!/usr/bin/env bash
# =============================================================================
# 02_setup_tickets.sh
#
# Creates the ticket queue for attack 2 (setup_tickets.sql): schema INJ_LAB
# (no authentication), table DBA_TICKETS with six invented tickets, one of
# which carries a hidden instruction, and SELECT on it for the agent's role.
#
# Run as the lab user, after ./01_prepare_agent.sh (which rebuilds the role
# and would remove this grant). Rerun it before each attack 2 run if an agent
# ever managed to change the table: it always starts from the same rows.
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

step "Ticket queue ${INJ_SCHEMA}.${INJ_TABLE}"
# Run the setup; on failure show the end of what SQL*Plus said.
if ! output="$(run_post09_sql setup_tickets.sql)"; then
    echo "${output}" | tail -20 >&2
    die "creating the ticket queue failed."
fi
# The completion marker proves the script ran to its last line.
grep -q SETUP_COMPLETE <<< "${output}" || { echo "${output}" | tail -20 >&2; die "unexpected output from SQL*Plus."; }
# The rows, the injected body and the grant, as the database reports them.
grep '^ROW '      <<< "${output}" | sed 's/^ROW /    /'
echo
grep '^INJECTED ' <<< "${output}" | sed 's/^INJECTED /    1005 body: /' | fold -s -w 110 | sed '2,$s/^/          /'
echo
grep '^GRANT '    <<< "${output}" | sed 's/^GRANT /    /'

step "Done"
info "Next: ./04_run_attacks.sh"
