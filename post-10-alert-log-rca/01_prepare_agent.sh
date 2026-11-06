#!/usr/bin/env bash
# =============================================================================
# 01_prepare_agent.sh
#
# Puts the agent's account into its post 10 state, deliberately and visibly:
#   1. its role is rebuilt from post 03's granted_views.txt PLUS this folder's
#      diag_views.txt: the alert log, trace files, sessions, locks, ASH, SQL
#      text and object names. Read-only, like everything before
#   2. SQL Firewall goes to OBSERVE mode: the post 03 allow-list is for a
#      different job; it logs the investigation's SQL instead of blocking it
#   3. a check that post 04's audit policy is on, so the run is recorded
#
# Run as the lab user. Safe to rerun. 99_cleanup.sh reverts steps 1 and 2.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-10 settings.
load_post10_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

step "1/3 Widen the agent's role for the investigation"
# Post 03's script does the work: revoke everything, then grant exactly the
# views in both lists. What was added is always one file you can read.
EXTRA_VIEW_FILES="${POST10_DIR}/diag_views.txt" "${POST03_DIR}/01_least_privilege.sh"

step "2/3 SQL Firewall to observe mode"
# Logs every statement outside the post 03 allow-list, blocks none.
"${POST03_DIR}/04_sql_firewall.sh" observe | grep -A4 '=== Allow-list' | sed 's/^/    /'

step "3/3 Is the agent audited?"
# Post 04's policy must be enabled for the agent, or the run leaves no record.
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
info "Next: ./02_create_incident.sh"
