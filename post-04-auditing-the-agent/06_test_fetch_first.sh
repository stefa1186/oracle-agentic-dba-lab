#!/usr/bin/env bash
# =============================================================================
# 06_test_fetch_first.sh
#
# Tests a blind spot found on 2026-11-05 (post 10's second run): a SELECT
# with the row-limiting clause (FETCH FIRST n ROWS ONLY) runs, but this
# post's audit policy, ACTIONS ALL ONLY TOPLEVEL, records nothing for it.
# Models write that clause all the time.
#
#   1. SQL Firewall to observe mode (the test is about auditing; the post 03
#      allow-list would block the new statements)
#   2. fetch_first_tests.sql through SQLcl MCP as the agent, without a model:
#      three statements, each without and with FETCH FIRST. For each one:
#      did the agent's policy record it?
#   3. the cause: the same replay with a second, TEMPORARY policy without
#      "ONLY TOPLEVEL" enabled too, and which policy recorded what
#   4. the result
# The temporary policy is dropped and the firewall set back to enforcing at
# the end, also after an error. Nothing else changes.
#
# Oracle analogy: checking that a trigger fires for every way a table can be
# changed, not just the one you thought of.
#
# Run as the lab user, after 01_audit_policy.sh.
# Exit code: 0 if the agent's policy recorded every statement, 1 otherwise.
# =============================================================================

# Stop on unset variables and pipeline failures. Not -e: the report must
# still print, and the cleanup run, if a step fails.
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

# The temporary policy of step 3: ACTIONS ALL, without ONLY TOPLEVEL.
TEST_POLICY="AI_AGENT_FETCH_TEST"
# The statements under test.
TESTS="${POST04_DIR}/fetch_first_tests.sql"
# The firewall script of post 03 (observe / enforce).
FIREWALL="${POST04_DIR}/../post-03-least-privilege/04_sql_firewall.sh"
# One temporary file for the audit export.
tmp="$(mktemp)"

# UTC time with microseconds, the format fetch_audit_jsonl expects.
now_utc() { date -u '+%Y-%m-%d %H:%M:%S.%6N'; }

# At exit, whatever happened: drop the temporary policy (ignoring "doesn't
# exist"), firewall back to enforcing, temporary file removed.
cleanup() {
    db_sqlplus <<SQL >/dev/null 2>&1
alter session set container = FREEPDB1;
begin execute immediate 'noaudit policy ${TEST_POLICY} by ${AGENT_DB_USER}'; exception when others then null; end;
/
begin execute immediate 'drop audit policy ${TEST_POLICY}'; exception when others then null; end;
/
exit
SQL
    "${FIREWALL}" enforce >/dev/null 2>&1 || warn "could not set the SQL Firewall back to enforcing: run ${FIREWALL} enforce"
    rm -f "${tmp}"
}
trap cleanup EXIT

# For each statement of the test file: how many audit records each policy
# wrote for it, in the export "$1". The statements are matched like
# 04_compare.sh does (audit_report.norm: no comments, no case, one line).
# Prints one line per statement; the last line is "MISSING=<n>": statements
# the agent's policy did not record.
per_statement() {
    local show=()
    [[ "$2" == "yes" ]] && show=(--show-test)
    python3 "${POST04_DIR}/fetch_first_report.py" --export "$1" --tests "${TESTS}" \
        --agent-policy "${AUDIT_POLICY}" --test-policy "${TEST_POLICY}" "${show[@]}"
}

step "1/4 SQL Firewall to observe mode, for this test"
"${FIREWALL}" observe >/dev/null || die "could not set the SQL Firewall to observe mode."
info "Observe: statements outside the allow-list run, and are logged."

step "2/4 The statements, as ${AGENT_DB_USER} through SQLcl MCP (no model), and the audit trail"
started="$(now_utc)"
replay "${TESTS}"
replay_rc=$?
ended="$(now_utc)"
fetch_audit_jsonl "${started}" "${ended}" > "${tmp}"
report="$(per_statement "${tmp}" no)"
grep -v '^MISSING=' <<< "${report}" | sed 's/^/    /'
missing="$(sed -n 's/^MISSING=//p' <<< "${report}")"

step "3/4 The cause: the same replay with a second policy, WITHOUT ONLY TOPLEVEL"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
-- A leftover from an interrupted run goes first.
begin execute immediate 'noaudit policy ${TEST_POLICY} by ${AGENT_DB_USER}'; exception when others then null; end;
/
begin execute immediate 'drop audit policy ${TEST_POLICY}'; exception when others then null; end;
/
create audit policy ${TEST_POLICY} actions all;
audit policy ${TEST_POLICY} by ${AGENT_DB_USER};
select 'TEST_POLICY_READY' from dual;
exit
SQL
)"; then
    echo "${output}" >&2
    die "creating the temporary policy failed."
fi
grep -q TEST_POLICY_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "Temporary policy ${TEST_POLICY}: ACTIONS ALL, enabled for ${AGENT_DB_USER} (new sessions)."
# The audit windows are widened by AUDIT_WINDOW_MARGIN seconds: wait that
# long (plus one), so this window can't reach back into step 2's records.
sleep $(( AUDIT_WINDOW_MARGIN + 1 ))
started="$(now_utc)"
replay "${TESTS}" >/dev/null
ended="$(now_utc)"
fetch_audit_jsonl "${started}" "${ended}" > "${tmp}"
per_statement "${tmp}" yes | grep -v '^MISSING=' | sed 's/^/    /'

step "4/4 Result"
if (( replay_rc != 0 )); then
    info "CHECK: not every statement ran (see step 2); the audit result says nothing."
    exit 1
elif [[ "${missing}" == "0" ]]; then
    info "PASS: ${AUDIT_POLICY} recorded every statement."
    exit 0
else
    info "FINDING: ${missing} of the statements ran, and ${AUDIT_POLICY} (ACTIONS ALL ONLY TOPLEVEL) recorded nothing for them."
    info "A policy without ONLY TOPLEVEL records them, along with SQLcl's recursive SQL (see step 3)."
    exit 1
fi
