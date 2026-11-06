#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Removes post 07: the advisor task POST07_STA, the profile POST07_PROFILE (if
# a test was interrupted), the application user TUNE_LAB with its table and
# indexes, and its password file. The agent's account was never changed.
# Kept: the measurements, the context pack, the advisor report, the runs.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-07 settings.
load_post07_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This drops ${TUNE_SCHEMA}, the advisor task and any test profile. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "Advisor task, test profile, ${TUNE_SCHEMA}"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
begin
    -- The profile a test may have left (it normally drops it itself).
    dbms_sqltune.drop_sql_profile(name => 'POST07_PROFILE', ignore => true);
    -- The advisor's task.
    begin
        dbms_sqltune.drop_tuning_task('POST07_STA');
    exception
        -- ORA-13605: no such task. Fine.
        when others then if sqlcode != -13605 then raise; end if;
    end;
    -- Sessions of the application user, so it can be dropped.
    for s in (select sid, serial# from v\$session where username = '${TUNE_SCHEMA}') loop
        begin
            execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
        exception
            when others then if sqlcode != -30 then raise; end if;
        end;
    end loop;
end;
/
declare
    l_left pls_integer;
begin
    -- KILL SESSION returns before the session is gone: wait (at most 60 s).
    for i in 1 .. 60 loop
        select count(*) into l_left from v\$session where username = '${TUNE_SCHEMA}';
        exit when l_left = 0;
        dbms_session.sleep(1);
    end loop;
    execute immediate 'drop user ${TUNE_SCHEMA} cascade';
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
rm -f "${TUNE_PWD_FILE}"
info "Dropped (where present): POST07_PROFILE, POST07_STA, ${TUNE_SCHEMA}; password file deleted."

step "Done"
info "Evidence kept in ${POST07_OUT}."
