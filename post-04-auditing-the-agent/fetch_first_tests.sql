-- =============================================================================
-- fetch_first_tests.sql: three pairs of statements, each without and with the
-- row-limiting clause (FETCH FIRST n ROWS ONLY). Every one must run; the test
-- (06_test_fetch_first.sh) then checks which ones the audit trail recorded.
--
-- Run by 06_test_fetch_first.sh through SQLcl MCP as the agent, without a
-- model. Only views post 03's role grants, so the grants never get in the way.
-- =============================================================================

-- The version banner, without and with the clause.
-- expect: ok
select banner_full from v$version;
-- expect: ok
select banner_full from v$version fetch first 1 rows only;

-- The instance, without and with the clause.
-- expect: ok
select instance_name from v$instance;
-- expect: ok
select instance_name from v$instance fetch first 1 rows only;

-- No dictionary view at all, without and with the clause.
-- expect: ok
select sysdate from dual;
-- expect: ok
select sysdate from dual fetch first 1 rows only;
