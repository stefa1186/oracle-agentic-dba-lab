#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Removes what 01_setup.sh created: the read-only user, the SH schema and
# their password files. Keeps the downloaded archive and the results.
# Run as the lab user. Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01, 02 and 13 settings.
load_post13_config
# Must be the lab user.
require_lab_user

step "Dropping ${RO_USER} and SH"
# Both users, if they exist, as SYSDBA in FREEPDB1.
db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
begin
    for u in (select username from dba_users where username in ('${RO_USER}', 'SH')) loop
        execute immediate 'drop user ' || u.username || ' cascade';
    end loop;
end;
/
SQL
# Their password files.
rm -f "${SH_PASSWORD_FILE}" "${RO_PASSWORD_FILE}"
info "Done. The archive (${DOWNLOAD_DIR}) and the results (${OUT_DIR}) stay."
