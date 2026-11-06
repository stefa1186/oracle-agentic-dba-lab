#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Undoes post 03 and puts the agent's account back in its post 02 state:
#   1. SQL Firewall: allow-list, capture and logs for the agent removed
#   2. the agent back on the DEFAULT profile; role and profile dropped
#   3. post 02's grants restored (CREATE SESSION + SELECT_CATALOG_ROLE), by
#      rerunning post 02's 02_create_agent_user.sh (same password)
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-03 settings.
load_post03_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This removes the firewall rules, ${AGENT_ROLE} and ${AGENT_PROFILE}, and restores post 02's grants. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "1/3 SQL Firewall"
"${POST03_DIR}/04_sql_firewall.sh" remove

step "2/3 Role and profile"
db_sqlplus <<SQL >/dev/null
whenever sqlerror exit failure
alter session set container = FREEPDB1;
-- Back to the default profile, then drop the role and profile if present.
alter user ${AGENT_DB_USER} profile default;
begin execute immediate 'drop role ${AGENT_ROLE}';       exception when others then if sqlcode != -1919 then raise; end if; end;
/
begin execute immediate 'drop profile ${AGENT_PROFILE}'; exception when others then if sqlcode != -2380 then raise; end if; end;
/
exit
SQL
info "${AGENT_ROLE} and ${AGENT_PROFILE} dropped."

step "3/3 Post 02 grants"
"${POST03_DIR}/../post-02-plugging-in-mcp/02_create_agent_user.sh"

step "Done"
info "The agent's account is back to its post 02 state."
