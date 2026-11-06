-- =============================================================================
-- approved_queries.sql: the SQL the agent is approved to run.
--
-- 04_sql_firewall.sh capture replays these statements through SQLcl MCP as
-- the agent (no model) while the SQL Firewall is capturing. The firewall
-- also records the statements SQLcl itself runs when the MCP server
-- connects. The resulting allow-list is then enforced: any other SQL from
-- the agent is rejected by the database with ORA-47605.
--
-- Oracle analogy: an allow-list of SQL, like a firewall rule set, enforced
-- inside the database rather than in the prompt.
--
-- Keep the text identical to the "ok" statements in privilege_tests.sql.
-- To approve a new query: add it here, then rerun ./04_sql_firewall.sh capture.
-- =============================================================================

select banner_full from v$version;

select name, open_mode, log_mode from v$database;

select instance_name, version_full, startup_time, status from v$instance;

select tablespace_name, used_percent from dba_tablespace_usage_metrics order by used_percent desc;
