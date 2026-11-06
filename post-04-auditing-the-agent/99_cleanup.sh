#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Switches post 04's auditing off: the audit policy is removed (and the
# MODULE/ACTION context setting of earlier versions, if still present). The audit RECORDS already written are kept: they
# are evidence, and deleting audit data deserves its own deliberate decision.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
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

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This stops auditing ${AGENT_DB_USER} (records are kept). Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "Removing audit settings for ${AGENT_DB_USER}"
db_sqlplus <<SQL >/dev/null
alter session set container = FREEPDB1;
-- Each step ignores "nothing to remove", so the script is safe to rerun.
begin execute immediate 'noaudit context namespace userenv attributes module, action by ${AGENT_DB_USER}'; exception when others then null; end;
/
begin execute immediate 'noaudit policy ${AUDIT_POLICY} by ${AGENT_DB_USER}'; exception when others then null; end;
/
begin execute immediate 'drop audit policy ${AUDIT_POLICY}'; exception when others then null; end;
/
exit
SQL
info "Policy ${AUDIT_POLICY} removed; existing audit records kept."
