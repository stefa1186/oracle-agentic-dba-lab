#!/usr/bin/env bash
# =============================================================================
# 03_save_connection.sh
#
# Saves the SQLcl connection the agent uses through MCP, named "agent",
# with its password stored in SQLcl's connection store (~/.dbtools).
#
# Why this matters: the MCP server connects by NAME. The model asks for
# "connect to agent"; it never sees the user name's password, and nothing in
# the prompt or the agent's logs contains it.
# Oracle analogy: the secure external password store (mkstore), which lets
# cron scripts run "connect /@db" with no password in the script.
#
# Run as the lab user. Deterministic: -replace overwrites any previous
# connection of the same name, so every run leaves exactly one, identical,
# saved connection. Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01 and post 02 settings.
load_post02_config
# Must be the lab user, in a proper login session.
require_lab_user
# SQLcl must be installed and the database up.
require_sqlcl
require_database
# The agent's password must exist (02_create_agent_user.sh).
[[ -f "${AGENT_PASSWORD_FILE}" ]] || die "no agent password. Run ./02_create_agent_user.sh first."

# The database as seen from this server: listener on loopback, FREEPDB1 service.
CONNECT_STRING="//127.0.0.1:${DB_PORT}/FREEPDB1"

step "1/2 Save connection '${MCP_CONNECTION}'"
# The commands go to SQLcl on stdin, so the password never appears on a
# command line. "conn -save NAME -savepwd -replace" connects, and on success
# stores the details and the password under NAME, replacing an old entry.
agent_pwd="$(cat "${AGENT_PASSWORD_FILE}")"
save_output="$("${SQLCL_BIN}" -S /nolog <<SQL 2>&1
conn -save ${MCP_CONNECTION} -savepwd -replace ${AGENT_DB_USER}/${agent_pwd}@${CONNECT_STRING}
exit
SQL
)" || true
# Drop the variable as soon as it isn't needed.
unset agent_pwd

step "2/2 Test the saved connection"
# Connect by name only, exactly as the MCP server will, and ask who we are.
test_output="$("${SQLCL_BIN}" -S /nolog <<SQL 2>&1
conn -name ${MCP_CONNECTION}
select 'CONNECTED_AS=' || user from dual;
exit
SQL
)" || true
# Success means the query ran as the agent's user.
if grep -q "CONNECTED_AS=${AGENT_DB_USER}" <<< "${test_output}"; then
    info "Connection '${MCP_CONNECTION}' works: connects as ${AGENT_DB_USER} to ${CONNECT_STRING}."
else
    # Show both outputs to explain the failure.
    echo "--- save:" >&2; echo "${save_output}" >&2
    echo "--- test:" >&2; echo "${test_output}" >&2
    die "the saved connection '${MCP_CONNECTION}' does not work."
fi

step "Done"
info "Next: ./04_check_restrict.sh"
