#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Returns the lab to its post 04 state:
#   1. drops everything 02_seed_known_problems.sh created (schema HC_SEED,
#      account HC_LEGACY, tablespace HC_SMALL and its datafile)
#   2. rebuilds the agent's role from post 03's granted_views.txt alone
#      (the health-check views are revoked)
#   3. puts SQL Firewall back to enforcing
# The evidence (answer key, checklist output, runs, scorecards) is kept.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-05 settings.
load_post05_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This drops ${HC_SCHEMA}, ${HC_LEGACY_USER} and tablespace ${HC_TABLESPACE}, and narrows ${AGENT_DB_USER} back to post 03. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "1/3 Drop the seeded problems"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
-- Each drop ignores "doesn't exist", so the script is safe to rerun.
begin execute immediate 'drop user ${HC_SCHEMA} cascade';
exception when others then if sqlcode != -1918 then raise; end if; end;
/
begin execute immediate 'drop user ${HC_LEGACY_USER} cascade';
exception when others then if sqlcode != -1918 then raise; end if; end;
/
-- The tablespace last: its segments belonged to ${HC_SCHEMA}.
begin execute immediate 'drop tablespace ${HC_TABLESPACE} including contents and datafiles';
exception when others then if sqlcode != -959 then raise; end if; end;
/
select 'CLEANUP_COMPLETE' from dual;
exit
SQL
)"; then
    # Show what SQL*Plus said, then stop.
    echo "${output}" >&2
    die "dropping the seeded problems failed."
fi
grep -q CLEANUP_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "Dropped (where present): ${HC_SCHEMA}, ${HC_LEGACY_USER}, ${HC_TABLESPACE}."

step "2/3 The agent's role back to post 03"
# No EXTRA_VIEW_FILES: only post 03's granted_views.txt is granted.
env -u EXTRA_VIEW_FILES "${POST03_DIR}/01_least_privilege.sh"

step "3/3 SQL Firewall back to enforcing"
"${POST03_DIR}/04_sql_firewall.sh" enforce

step "Done"
info "Evidence kept in ${POST05_OUT}."
