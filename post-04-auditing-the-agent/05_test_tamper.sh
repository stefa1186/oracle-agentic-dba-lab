#!/usr/bin/env bash
# =============================================================================
# 05_test_tamper.sh
#
# Proves the agent cannot touch its own audit trail: it tries to read it,
# delete from it, switch the policy off and purge the trail (tamper_tests.sql),
# through SQLcl MCP as the agent, without a model. Every attempt must fail.
# Then it shows that the database recorded the attempts themselves.
#
# Oracle analogy: a user who can't touch the redo log, and whose attempt to
# do so ends up in the redo log.
#
# Run as the lab user, after 01_audit_policy.sh.
# Exit code: 0 if every attempt failed, 1 otherwise.
# =============================================================================

# Stop on unset variables and pipeline failures. Not -e: the report must
# still print if a test fails.
set -uo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-04 settings.
load_post04_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# UTC time with microseconds, the format fetch_audit_jsonl expects.
now_utc() { date -u '+%Y-%m-%d %H:%M:%S.%6N'; }

step "Tamper attempts as ${AGENT_DB_USER}, through SQLcl MCP (no model)"
started="$(now_utc)"
# The tests: one PASS/FAIL line each; the exit code says whether all failed as expected.
replay "${POST04_DIR}/tamper_tests.sql"
rc=$?
ended="$(now_utc)"

step "What the database recorded about those attempts"
# The same window, read from the audit trail (as SYSDBA, which the agent can't do).
tmp="$(mktemp)"
fetch_audit_jsonl "${started}" "${ended}" > "${tmp}"
python3 "${POST04_DIR}/audit_report.py" --audit "${tmp}" --mode show
report_rc=$?
rm -f "${tmp}"

step "Result"
if (( rc != 0 )); then
    info "FAIL: at least one attempt did not fail (see the FAIL lines above)."
elif (( report_rc != 0 )); then
    # The attempts failed as they should, but the audit listing could not be
    # produced: don't claim they were recorded.
    info "PASS (attempts): every attempt failed."
    info "CHECK (audit): the audit listing could not be read (see above)."
    rc=1
else
    info "PASS: every attempt to read, delete or switch off the audit trail failed, and was itself recorded."
fi
exit "${rc}"
