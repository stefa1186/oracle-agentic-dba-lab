#!/usr/bin/env bash
# =============================================================================
# 02_show_privileges.sh
#
# Shows everything the agent's account can do: roles, system privileges,
# object privileges (direct and through its role), the profile limits, and
# the SQL Firewall state. Read-only; safe to run any number of times.
#
# Oracle analogy: the classic "what can this user actually do?" report, the
# one every audit asks for.
#
# Run as the lab user.
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

# One read-only report.
db_sqlplus <<SQL
-- tab off: spaces instead of tabs, so the output pastes into a post unchanged.
set linesize 160 pagesize 100 feedback off tab off
-- PROFILE is 128 characters wide by default, which pushed LIMIT onto the next line.
column profile       format a18
column grantee       format a16
column granted_role  format a24
column privilege     format a24
column object        format a40
column resource_name format a26
column limit         format a12
column status        format a10
column enforce       format a14
column block         format a6
alter session set container = FREEPDB1;

prompt
prompt === Roles granted to ${AGENT_DB_USER}
select granted_role, default_role from dba_role_privs where grantee = '${AGENT_DB_USER}' order by 1;

prompt
prompt === System privileges (direct and through roles)
select grantee, privilege from dba_sys_privs
where  grantee = '${AGENT_DB_USER}'
   or  grantee in (select granted_role from dba_role_privs where grantee = '${AGENT_DB_USER}')
order  by 1, 2;

prompt
prompt === Object privileges (direct and through roles)
select grantee, privilege, owner || '.' || table_name as object from dba_tab_privs
where  grantee = '${AGENT_DB_USER}'
   or  grantee in (select granted_role from dba_role_privs where grantee = '${AGENT_DB_USER}')
order  by 1, 3;

prompt
prompt === Profile of ${AGENT_DB_USER} and its explicit limits
select u.profile, p.resource_name, p.limit
from   dba_users u join dba_profiles p on p.profile = u.profile
where  u.username = '${AGENT_DB_USER}' and p.limit not in ('DEFAULT')
order  by p.resource_name;

prompt
prompt === SQL Firewall
select status from dba_sql_firewall_status;
select username, status, enforce, block from dba_sql_firewall_allow_lists where username = '${AGENT_DB_USER}';
exit
SQL
