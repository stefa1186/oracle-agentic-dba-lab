-- =============================================================================
-- privilege_tests.sql: what the agent's account may and may not do.
--
-- Run by 03_test_privileges.sh through SQLcl MCP as the agent (the exact path
-- an AI agent uses), without a model, so the results are the same every time.
--
-- Each statement has an expected outcome:
--   -- expect: ok      the statement must succeed
--   -- expect: error   the statement must fail (the actual ORA- code is shown)
--
-- The "ok" statements are the same text as approved_queries.sql, so these
-- tests keep passing when the SQL Firewall is enforcing.
-- =============================================================================

-- ---- Allowed: the views in granted_views.txt --------------------------------

-- expect: ok
select banner_full from v$version;

-- expect: ok
select name, open_mode, log_mode from v$database;

-- expect: ok
select instance_name, version_full, startup_time, status from v$instance;

-- expect: ok
select tablespace_name, used_percent from dba_tablespace_usage_metrics order by used_percent desc;

-- ---- Denied: dictionary views it could read in post 02 (SELECT_CATALOG_ROLE) --

-- expect: error
select username, account_status from dba_users;

-- expect: error
select owner, count(*) from dba_objects group by owner;

-- expect: error
select sid, username, program from v$session;

-- ---- Denied: anything that changes the database ----------------------------

-- expect: error
create table ai_agent_probe (n number);

-- expect: error
alter system flush shared_pool;

-- expect: error
grant dba to ai_agent;
