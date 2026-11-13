#!/usr/bin/env bash
# =============================================================================
# 01_audit_policy.sh
#
# Turns on an audit trail for the agent that the agent cannot touch: a
# Unified Auditing policy, ACTIONS ALL ONLY TOPLEVEL, enabled for the agent's
# user only. Every statement it sends (successful or failed), plus logon and
# logoff, is recorded by the database in AUDSYS's audit trail.
#
# Which model sent a statement is in the record too: SQLcl's MCP server puts
# "/* LLM in use is <model> */" into every statement it runs for the model
# (with the model ID the harness fills in), and the audit trail keeps the SQL.
#
# Why this and not the other logs:
#   - SQLcl's MCP log only exists if the agent owns it (and could edit it)
#   - the SQL Firewall log misses statements the grants already rejected
#   - the agent's own summary is not a record (post 02: 8 queries, no answer)
# Oracle analogy: the redo log of who did what. Written by the database, as
# it happens, out of reach of the session it describes.
#
# Run as the lab user. SQL runs as SYSDBA inside the container.
# Deterministic: the policy is dropped and recreated on every run, so its
# definition always matches this script. Existing audit records are kept.
# Safe to rerun. New settings apply to NEW agent sessions.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-04 settings.
load_post04_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

step "Audit policy ${AUDIT_POLICY} for ${AGENT_DB_USER}"
# Recreate the policy from scratch. NOAUDIT and DROP fail harmlessly when
# there is nothing to remove, so their errors are ignored; CREATE and AUDIT
# must succeed ("whenever sqlerror").
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
-- Remove any previous definition (ignore "not enabled" / "does not exist").
begin execute immediate 'noaudit policy ${AUDIT_POLICY} by ${AGENT_DB_USER}'; exception when others then null; end;
/
begin execute immediate 'drop audit policy ${AUDIT_POLICY}'; exception when others then null; end;
/
-- An earlier version of this script also audited USERENV MODULE/ACTION. The
-- database accepted it but recorded no values, so it was dropped; remove it
-- here so every lab ends up in the same state.
begin execute immediate 'noaudit context namespace userenv attributes module, action by ${AGENT_DB_USER}'; exception when others then null; end;
/
-- Every action: SELECT, DML, DDL, PL/SQL, logon, logoff ... ONLY TOPLEVEL
-- records the statements the client sends (what the agent did), not the
-- recursive SQL inside every PL/SQL block (hundreds of internal statements
-- per SQLcl connect, which would bury the agent's own actions).
create audit policy ${AUDIT_POLICY} actions all only toplevel;
-- ... for the agent's user only. Successful AND failed statements are recorded.
audit policy ${AUDIT_POLICY} by ${AGENT_DB_USER};
-- Show the result for the run notes.
select 'ENABLED: ' || policy_name || ' for ' || entity_name || ' (success=' || success || ', failure=' || failure || ')'
from   audit_unified_enabled_policies
where  policy_name = '${AUDIT_POLICY}';
exit
SQL
)"; then
    echo "${output}" >&2
    die "creating the audit policy failed."
fi
grep 'ENABLED:' <<< "${output}" | sed 's/^/    /' || die "the policy is not enabled (see above)."

step "Done"
info "Every top-level statement of ${AGENT_DB_USER} is now audited (new sessions),"
# Found on 2026-11-05 and tested by 06_test_fetch_first.sh: not a SELECT with
# FETCH FIRST n ROWS ONLY, which an ONLY TOPLEVEL policy does not record.
info "except SELECTs with FETCH FIRST n ROWS ONLY: see ./06_test_fetch_first.sh"
info "Next: ./05_test_tamper.sh, then the agent run (see README)"
