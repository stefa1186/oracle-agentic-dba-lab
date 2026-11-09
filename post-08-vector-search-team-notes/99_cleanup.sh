#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Removes post 08 from the database: the application user RAG_LAB (with it the
# embedding model and the team note table), the directory object, the model file
# inside the container, and the password file. The agent's account was never
# changed. Kept: the downloaded model on the server (MODEL_DIR, so a rerun
# needn't download it again), the search results, the runs, the scorecard.
#
# Run as the lab user. Asks for confirmation unless --yes is given.
# Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-08 settings.
load_post08_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# Confirmation, unless --yes.
case "${1:-}" in
    --yes) ;;
    "")    read -r -p "This drops ${RAG_SCHEMA} (model and team note table) and the directory. Type 'cleanup' to confirm: " answer
           [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed." ;;
    *)     die "usage: $0 [--yes]" ;;
esac

step "${RAG_SCHEMA}, its model and table, the directory"
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
begin
    -- Sessions of the application user, so it can be dropped.
    for s in (select sid, serial# from v\$session where username = '${RAG_SCHEMA}') loop
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
        select count(*) into l_left from v\$session where username = '${RAG_SCHEMA}';
        exit when l_left = 0;
        dbms_session.sleep(1);
    end loop;
    execute immediate 'drop user ${RAG_SCHEMA} cascade';
exception
    -- ORA-01918: already gone.
    when others then if sqlcode != -1918 then raise; end if;
end;
/
begin
    execute immediate 'drop directory rag_model_dir';
exception
    -- ORA-04043: no such directory.
    when others then if sqlcode != -4043 then raise; end if;
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
# The model file inside the container, and the password file.
podman exec "${DB_CONTAINER}" rm -rf "${CONTAINER_MODEL_DIR}"
rm -f "${RAG_PWD_FILE}"
info "Dropped: ${RAG_SCHEMA}, RAG_MODEL_DIR, ${CONTAINER_MODEL_DIR} in the container, the password file."

step "Done"
info "Kept: ${MODEL_DIR} (the downloaded model) and the evidence in ${POST08_OUT}."
