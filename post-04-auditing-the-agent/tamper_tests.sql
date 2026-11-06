-- =============================================================================
-- tamper_tests.sql: the agent tries to read, delete or switch off its own
-- audit trail. Every attempt must fail.
--
-- Run by 05_test_tamper.sh through SQLcl MCP as the agent, without a model.
-- "-- expect: error" accepts any Oracle error and reports the actual code
-- (ORA-00942, ORA-01031, ORA-06550 ... or ORA-47605 if the SQL Firewall is
-- enforcing).
-- =============================================================================

-- Read the audit trail.
-- expect: error
select count(*) from unified_audit_trail;

-- Read the table behind it directly.
-- expect: error
select count(*) from audsys."AUD$UNIFIED";

-- Delete from it.
-- expect: error
delete from audsys."AUD$UNIFIED";

-- Switch off the policy that records it.
-- expect: error
noaudit policy ai_agent_all_actions by ai_agent;

-- Purge the whole unified audit trail.
-- expect: error
begin dbms_audit_mgmt.clean_audit_trail(audit_trail_type => dbms_audit_mgmt.audit_trail_unified, use_last_arch_timestamp => false); end;
