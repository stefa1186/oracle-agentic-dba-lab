#!/usr/bin/env bash
# =============================================================================
# 01_least_privilege.sh
#
# Puts the agent's database account into its least-privilege state:
#   1. a profile that limits sessions, CPU and reads per call, idle and
#      connect time, and failed logins (a runaway loop hits a wall)
#   2. a role with SELECT on exactly the views in granted_views.txt
#   3. the user reset to exactly: CREATE SESSION + that role + that profile.
#      SELECT_CATALOG_ROLE from post 02, and anything else, is revoked.
#
# Run as the lab user. SQL runs as SYSDBA inside the container (no password).
#
# EXTRA_VIEW_FILES=<file ...> adds more view lists (see read_granted_views in
# lib.sh); post 05 uses it to widen the role for its health check.
#
# Deterministic: the role is dropped and rebuilt from granted_views.txt, and
# every privilege not on the list is revoked, so the result depends only on
# the files in this folder, never on what was granted before.
# Oracle analogy: "revoke all, then grant what the job needs", scripted.
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

step "Views granted to ${AGENT_ROLE}"
# Read the list (validated: plain upper-case names only).
mapfile -t views < <(read_granted_views)
(( ${#views[@]} > 0 )) || die "granted_views.txt lists no views."
# Build the GRANT statements in bash. They go into the SQL below as a
# variable, so a "$" in names like V_$VERSION is never touched by the shell.
grants_sql=""
# The same names as a quoted SQL list, to report what the old role held that
# the new one won't (the role is dropped and recreated, so those grants vanish
# with it and would otherwise go unreported).
in_list=""
for v in "${views[@]}"; do
    info "SELECT on SYS.${v}"
    grants_sql+="grant select on sys.${v} to ${AGENT_ROLE};"$'\n'
    in_list+="${in_list:+,}'${v}'"
done

step "Applying profile, role and grants"
# One SQL*Plus session; any error stops it ("whenever sqlerror").
if ! output="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
-- Work inside the pluggable database.
alter session set container = FREEPDB1;
-- Enable DBMS_OUTPUT AFTER switching container: the setting belongs to the
-- container session, so enabling it before the switch would be lost.
set serveroutput on

-- 1. Profile: create if missing, then set every limit explicitly.
declare
    l_count number;
begin
    select count(*) into l_count from dba_profiles where profile = '${AGENT_PROFILE}';
    if l_count = 0 then
        execute immediate 'create profile ${AGENT_PROFILE} limit sessions_per_user 1';
    end if;
end;
/
alter profile ${AGENT_PROFILE} limit
    sessions_per_user      ${PROFILE_SESSIONS_PER_USER}
    cpu_per_call           ${PROFILE_CPU_PER_CALL}
    logical_reads_per_call ${PROFILE_LOGICAL_READS_PER_CALL}
    idle_time              ${PROFILE_IDLE_TIME}
    connect_time           ${PROFILE_CONNECT_TIME}
    failed_login_attempts  ${PROFILE_FAILED_LOGIN_ATTEMPTS}
    password_life_time     unlimited;

-- 2. Role: first report what the current role holds that isn't on the list
--    (it goes with the role), then drop it (if present) and recreate it empty,
--    then grant exactly the listed views.
begin
    for g in (select privilege, owner, table_name from dba_tab_privs
              where grantee = '${AGENT_ROLE}' and table_name not in (${in_list})
              order by table_name) loop
        dbms_output.put_line('revoked from role ${AGENT_ROLE}: ' || g.privilege || ' on ' || g.owner || '.' || g.table_name);
    end loop;
end;
/
begin
    execute immediate 'drop role ${AGENT_ROLE}';
exception
    -- ORA-01919: role does not exist (first run). Anything else is a real error.
    when others then if sqlcode != -1919 then raise; end if;
end;
/
create role ${AGENT_ROLE};
${grants_sql}
-- 3. User: revoke every role, system privilege (except CREATE SESSION)
--    and object privilege it holds, then grant exactly what it needs.
begin
    for r in (select granted_role from dba_role_privs where grantee = '${AGENT_DB_USER}') loop
        execute immediate 'revoke "' || r.granted_role || '" from ${AGENT_DB_USER}';
        dbms_output.put_line('revoked role ' || r.granted_role);
    end loop;
    for p in (select privilege from dba_sys_privs
              where grantee = '${AGENT_DB_USER}' and privilege <> 'CREATE SESSION') loop
        execute immediate 'revoke ' || p.privilege || ' from ${AGENT_DB_USER}';
        dbms_output.put_line('revoked system privilege ' || p.privilege);
    end loop;
    for t in (select owner, table_name, privilege from dba_tab_privs
              where grantee = '${AGENT_DB_USER}') loop
        execute immediate 'revoke ' || t.privilege || ' on "' || t.owner || '"."' || t.table_name || '" from ${AGENT_DB_USER}';
        dbms_output.put_line('revoked ' || t.privilege || ' on ' || t.owner || '.' || t.table_name);
    end loop;
end;
/
grant create session to ${AGENT_DB_USER};
grant ${AGENT_ROLE} to ${AGENT_DB_USER};
-- The role is active at every login.
alter user ${AGENT_DB_USER} default role all;
-- The limits apply.
alter user ${AGENT_DB_USER} profile ${AGENT_PROFILE};

-- Profile limits are only enforced when RESOURCE_LIMIT is TRUE (the default).
select 'RESOURCE_LIMIT=' || value from v\$parameter where name = 'resource_limit';
select 'LEAST_PRIVILEGE_READY' from dual;
exit
SQL
)"; then
    # Show what SQL*Plus said, then stop.
    echo "${output}" >&2
    die "applying least privilege failed."
fi

# Show what was revoked (the post 02 grants should appear here on the first run).
grep '^revoked' <<< "${output}" | sed 's/^/    /' || info "Nothing to revoke: the account and its role already had only the intended privileges."
# The marker must be there.
grep -q LEAST_PRIVILEGE_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
# Warn if profile limits would not be enforced.
if ! grep -q 'RESOURCE_LIMIT=TRUE' <<< "${output}"; then
    warn "RESOURCE_LIMIT is not TRUE: the profile's resource limits are NOT enforced."
fi

step "Done"
info "${AGENT_DB_USER}: CREATE SESSION + ${AGENT_ROLE} (${#views[@]} views), profile ${AGENT_PROFILE}."
info "Next: ./02_show_privileges.sh"
