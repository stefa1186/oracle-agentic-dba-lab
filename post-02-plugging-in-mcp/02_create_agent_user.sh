#!/usr/bin/env bash
# =============================================================================
# 02_create_agent_user.sh
#
# Creates the database account the AI agent connects as: AI_AGENT in FREEPDB1.
#
# Privileges in this post: CREATE SESSION and SELECT_CATALOG_ROLE. That is
# deliberately a little generous (it can read the whole data dictionary):
# post 03 takes it away and shows why. Nothing that can change data.
#
# Run as the lab user. The SQL runs as SYSDBA inside the database container
# (OS authentication there), so no DBA password is typed or stored anywhere.
#
# Deterministic: the password is generated once and kept in a private file;
# every run sets the account to exactly that password and these grants.
# Safe to rerun.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01 and post 02 settings.
load_post02_config
# Must be the lab user, in a proper login session.
require_lab_user
# The database must be up.
require_database

step "1/2 Agent password"
# Private folder for lab secrets (created by post 01, but make sure).
install -d -m 700 "${LAB_CONF_DIR}"
if [[ -f "${AGENT_PASSWORD_FILE}" ]]; then
    # Reuse it: rerunning must not change the password under the saved connection.
    info "Using the existing password in ${AGENT_PASSWORD_FILE}."
else
    # Random password: starts with a letter, has upper case, lower case and a
    # digit; letters and digits only, so it is safe inside SQL quotes. The file
    # is created private (umask 077) and has no trailing newline.
    ( umask 077 && python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("Agt" + "".join(secrets.choice(a) for _ in range(20)) + "7", end="")' > "${AGENT_PASSWORD_FILE}" )
    info "Generated a new password in ${AGENT_PASSWORD_FILE}."
fi
# Read it into a variable (used only inside the SQL sent on stdin below,
# never on a command line, where other users could see it in "ps").
agent_pwd="$(cat "${AGENT_PASSWORD_FILE}")"

step "2/2 Account ${AGENT_DB_USER} in FREEPDB1"
# The SQL goes to SQL*Plus on stdin. It creates the user if missing, or
# resets its password and unlocks it if present, then grants the two
# privileges. "whenever sqlerror" makes any SQL error fail the script.
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
-- Work inside the pluggable database, not the CDB root.
alter session set container = FREEPDB1;
-- Create or reset the account (idempotent).
declare
    l_count number;
begin
    select count(*) into l_count from dba_users where username = '${AGENT_DB_USER}';
    if l_count = 0 then
        execute immediate 'create user ${AGENT_DB_USER} identified by "${agent_pwd}"';
    else
        execute immediate 'alter user ${AGENT_DB_USER} identified by "${agent_pwd}" account unlock';
    end if;
end;
/
-- Allow it to log in.
grant create session to ${AGENT_DB_USER};
-- Allow it to read the data dictionary (to be removed in post 03).
grant select_catalog_role to ${AGENT_DB_USER};
-- Marker the script checks for.
select 'AGENT_USER_READY' from dual;
exit
SQL
)"; then
    # Show what SQL*Plus said, then stop.
    echo "${output}" >&2
    die "creating ${AGENT_DB_USER} failed."
fi
# Double-check the marker came back.
grep -q AGENT_USER_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "${AGENT_DB_USER} ready: CREATE SESSION, SELECT_CATALOG_ROLE."

step "Done"
info "Next: ./03_save_connection.sh"
