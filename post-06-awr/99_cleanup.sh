#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Removes post 06's workload: kills any of its sessions still connected, stops
# any scheduler job it still owns (left over from an earlier, job-based version
# of this post), and drops the schema with its tables. The agent's account was
# never changed in this post, so there is nothing to restore there.
#
# Kept: the AWR snapshots (they age out with the AWR retention period), the
# report, the answer key, the session logs, the runs and their scorecards:
# they are the evidence.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-06 settings.
load_post06_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This ends post 06's workload sessions and drops ${AWR_SCHEMA}. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "1/2 Stop the workload: jobs disabled and stopped, sessions killed"
# Same file as 02_generate_load.sh uses before its setup.
if ! output="$(run_post06_sql stop_workload.sql)"; then
    echo "${output}" >&2
    die "stopping the workload failed."
fi
grep -q WORKLOAD_STOPPED <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "No ${AWR_SCHEMA} job or session left."

step "2/2 Drop ${AWR_SCHEMA}"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
begin
    -- The schema, with its tables (and any jobs).
    execute immediate 'drop user ${AWR_SCHEMA} cascade';
exception
    -- ORA-01918: already gone.
    when others then if sqlcode != -1918 then raise; end if;
end;
/
select 'CLEANUP_COMPLETE' from dual;
exit
SQL
)"; then
    echo "${output}" >&2
    die "cleanup failed."
fi
grep -q CLEANUP_COMPLETE <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "Dropped (where present): ${AWR_SCHEMA}."

step "Done"
info "Evidence kept in ${POST06_OUT}; AWR snapshots age out with the AWR retention."
