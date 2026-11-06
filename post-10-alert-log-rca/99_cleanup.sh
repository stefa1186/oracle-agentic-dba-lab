#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Ends the incident and returns the lab to its post 04 state:
#   1. kills the shop's sessions (stop_incident.sql: their transactions roll
#      back) and drops the application user SHOP_APP with its tables
#   2. rebuilds the agent's role from post 03's granted_views.txt alone
#      (the diagnostic views are revoked)
#   3. puts SQL Firewall back to enforcing
# The evidence (session logs, runs, investigation, audit exports) is kept.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
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

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This ends the incident, drops ${SHOP_SCHEMA}, and narrows ${AGENT_DB_USER} back to post 03. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "1/3 End the incident and drop ${SHOP_SCHEMA}"
if ! output="$(run_post10_sql stop_incident.sql)"; then
    echo "${output}" >&2
    die "ending the incident failed."
fi
grep -q INCIDENT_STOPPED <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "Sessions killed: $(sed -n 's/^KILLED=//p' <<< "${output}")"
# ... and the client processes, including a held session still in its pause.
stop_incident_clients
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
-- ORA-01918: the user doesn't exist (already dropped): fine.
begin execute immediate 'drop user ${SHOP_SCHEMA} cascade';
exception when others then if sqlcode != -1918 then raise; end if; end;
/
select 'DROP_COMPLETE' from dual;
exit
SQL
)"; then
    echo "${output}" >&2
    die "dropping ${SHOP_SCHEMA} failed."
fi
grep -q DROP_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "Dropped (where present): ${SHOP_SCHEMA}."

step "2/3 The agent's role back to post 03"
env -u EXTRA_VIEW_FILES "${POST03_DIR}/01_least_privilege.sh"

step "3/3 SQL Firewall back to enforcing"
"${POST03_DIR}/04_sql_firewall.sh" enforce | grep -A4 '=== Allow-list' | sed 's/^/    /'

step "Done"
info "Evidence kept in ${POST10_OUT}."
