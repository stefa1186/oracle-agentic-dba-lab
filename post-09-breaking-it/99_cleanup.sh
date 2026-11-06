#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Returns the lab to its post 04 state:
#   1. drops the ticket queue (user INJ_LAB and its table; its grant to the
#      agent's role goes with it), and revokes DBA from the agent's user in
#      case any attack ever got it (it shouldn't: the check is a safety net)
#   2. rebuilds the agent's role from post 03's granted_views.txt alone
#   3. puts SQL Firewall back to enforcing
# The evidence (runs, audit and firewall exports, bypass results) is kept.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
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

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This drops ${INJ_SCHEMA} and puts ${AGENT_DB_USER} back to post 03 with the firewall enforcing. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "1/3 Drop the ticket queue"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
-- ORA-01918: the user doesn't exist (already dropped): fine.
begin execute immediate 'drop user ${INJ_SCHEMA} cascade';
exception when others then if sqlcode != -1918 then raise; end if; end;
/
-- ORA-01951: DBA was not granted (the expected case): fine.
begin execute immediate 'revoke dba from ${AGENT_DB_USER}';
exception when others then if sqlcode != -1951 then raise; end if; end;
/
-- What the agent's user holds directly now: roles and system privileges.
select 'DIRECT ' || granted_role from dba_role_privs where grantee = '${AGENT_DB_USER}'
union all
select 'DIRECT ' || privilege    from dba_sys_privs  where grantee = '${AGENT_DB_USER}'
order by 1;
select 'CLEANUP_COMPLETE' from dual;
exit
SQL
)"; then
    # Show what SQL*Plus said, then stop.
    echo "${output}" >&2
    die "dropping the ticket queue failed."
fi
grep -q CLEANUP_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "Dropped (where present): ${INJ_SCHEMA}. ${AGENT_DB_USER} holds directly:"
grep '^DIRECT ' <<< "${output}" | sed 's/^DIRECT /      /'

step "2/3 The agent's role back to post 03"
env -u EXTRA_VIEW_FILES "${POST03_DIR}/01_least_privilege.sh"

step "3/3 SQL Firewall back to enforcing"
"${POST03_DIR}/04_sql_firewall.sh" enforce

step "Done"
info "Evidence kept in ${POST09_OUT}."
