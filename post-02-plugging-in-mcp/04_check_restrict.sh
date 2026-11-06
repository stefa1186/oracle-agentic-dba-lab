#!/usr/bin/env bash
# =============================================================================
# 04_check_restrict.sh
#
# Proves that SQLcl, at the restrict level the agent gets (default 4), refuses
# to run operating-system commands, and that without it, it would not.
#
# Why this matters: SQLcl's "host" command (and "!") runs shell commands as
# the lab user. Through MCP, an agent could use it to read files or reach
# the OS. Since SQLcl 26.1.2 the MCP server starts UNRESTRICTED unless a
# level is given, so the harness always passes -R explicitly. This script
# shows the difference with a harmless command, "host id".
# Oracle analogy: like SQL*Plus -R: the same tool, with the dangerous
# commands switched off.
#
# Run as the lab user. Changes nothing; safe to run any number of times.
# Exit code: 0 if the restricted level blocks host commands, 1 otherwise.
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
# SQLcl must be installed.
require_sqlcl

# Run "host id" in SQLcl at a given restrict level; print what came back.
# "id" prints "uid=..." if the host command actually ran.
host_id_at_level() {
    printf 'host id\nexit\n' | "${SQLCL_BIN}" -S -R "$1" /nolog 2>&1 || true
}

step "Restrict level 0 (unrestricted, for comparison)"
out0="$(host_id_at_level 0)"
if grep -q 'uid=' <<< "${out0}"; then
    info "host id RAN: $(grep -m1 'uid=' <<< "${out0}")"
else
    info "host id did not run (unexpected, but harmless)."
fi

step "Restrict level ${SQLCL_RESTRICT} (what the agent gets)"
outR="$(host_id_at_level "${SQLCL_RESTRICT}")"
if grep -q 'uid=' <<< "${outR}"; then
    # The command ran: the agent could run OS commands. Fail loudly.
    info "host id RAN: $(grep -m1 'uid=' <<< "${outR}")"
    die "restrict level ${SQLCL_RESTRICT} does NOT block host commands. Use 4."
fi
# Show SQLcl's own refusal message, for the post. SQLcl prints it over three
# lines (the code, the command in quotes, "not available"), so join the first
# three non-empty lines and squeeze the spaces.
refusal="$(grep -v '^\s*$' <<< "${outR}" | head -3 | tr '\n' ' ' | tr -s ' ' | sed 's/ $//')"
info "host id BLOCKED: ${refusal:-(no output)}"

step "Result"
info "PASS: at restrict level ${SQLCL_RESTRICT}, SQLcl refuses OS commands."
info "Next: run the first contact (see README), and watch it with ./06_watch_agent_sessions.sh"
