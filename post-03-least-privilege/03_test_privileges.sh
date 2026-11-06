#!/usr/bin/env bash
# =============================================================================
# 03_test_privileges.sh
#
# Proves the least-privilege setup: runs privilege_tests.sql through SQLcl MCP
# as the agent (same server, restrict level, saved connection and tools as a
# real agent run) but WITHOUT a model, so the result is identical every time.
# Each statement has an expected outcome; one PASS/FAIL line per statement.
#
# Oracle analogy: a regression test for grants, instead of "I think it's fine".
#
# Run as the lab user, after 01_least_privilege.sh and the agent harness setup.
# Changes nothing (the "denied" statements are expected to fail).
# Exit code: 0 if every expectation is met, 1 otherwise.
# =============================================================================

# Stop on unset variables and pipeline failures. Not -e: the summary must
# still print when a test fails.
set -uo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-03 settings.
load_post03_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

step "Privilege tests as ${AGENT_DB_USER}, through SQLcl MCP (no model)"
# Run the tests; replay prints one PASS/FAIL line per statement and sets the exit code.
replay "${POST03_DIR}/privilege_tests.sql"
rc=$?

step "Result"
if (( rc == 0 )); then
    info "PASS: the agent can read exactly what it needs, and nothing else."
else
    info "FAIL: at least one expectation was not met (see the FAIL lines above)."
fi
exit "${rc}"
