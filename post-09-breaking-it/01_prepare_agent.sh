#!/usr/bin/env bash
# =============================================================================
# 01_prepare_agent.sh
#
# Puts the agent's account into its post 09 state, deliberately and visibly:
#   1. its role is rebuilt from post 03's granted_views.txt alone (the
#      narrowest state of the series; 02_setup_tickets.sh then adds SELECT on
#      the one ticket table attack 2 needs)
#   2. SQL Firewall goes to OBSERVE mode: the post 03 allow-list would reject
#      the agent's very first query, and the attacks would test nothing but
#      the firewall. In observe mode it still logs every statement it WOULD
#      have blocked, so the evidence shows both walls: what the grants
#      stopped, and what the firewall would have stopped
#   3. a check that post 04's audit policy is on, so every attempt is recorded
#
# Run as the lab user. Safe to rerun. 99_cleanup.sh reverts steps 1 and 2.
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

step "1/3 The agent's role back to post 03"
# Post 03's script does the work: revoke everything from the role, then grant
# exactly the views in granted_views.txt. No EXTRA_VIEW_FILES: nothing else.
env -u EXTRA_VIEW_FILES "${POST03_DIR}/01_least_privilege.sh"

step "2/3 SQL Firewall to observe mode"
# Logs every statement outside the post 03 allow-list, blocks none.
"${POST03_DIR}/04_sql_firewall.sh" observe

step "3/3 Is the agent audited?"
# Post 04's policy must be enabled for the agent, or the attacks leave no record.
enabled="$(db_sqlplus <<SQL | tr -d '[:space:]'
set heading off feedback off pagesize 0
alter session set container = FREEPDB1;
select count(*) from audit_unified_enabled_policies
where  policy_name = '${AUDIT_POLICY}' and entity_name = '${AGENT_DB_USER}';
exit
SQL
)"
# Exactly one enabled row: audited. Anything else: stop, the evidence would be missing.
[[ "${enabled}" == "1" ]] || die "audit policy ${AUDIT_POLICY} is not enabled for ${AGENT_DB_USER}: run ../post-04-auditing-the-agent/01_audit_policy.sh first."
info "Audit policy ${AUDIT_POLICY} is enabled for ${AGENT_DB_USER}."

step "Done"
info "Next: ./02_setup_tickets.sh"
