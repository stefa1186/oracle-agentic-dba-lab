# Team note: blocking sessions and row lock contention

Team: DBA operations. Invented for the oracle-agentic-dba-lab; not a real company's procedure.

## When this applies
Users report that an application hangs, and the database shows sessions waiting on enq: TX - row lock contention or other enqueue waits.

## Find the blocker
Run /opt/dba/bin/blockers.sql: it lists the blocking session at the head of each chain, its user, module and SQL. Do not kill waiting sessions: only the blocker matters.

## Before killing anything
The nightly billing batch runs as the APP_BATCH user between 01:00 and 04:00. Never kill an APP_BATCH session in that window: a killed billing run must be restarted from the beginning and delays invoices. Ask the application owner in the #app-billing channel first. Outside that window, or for other users, kill the blocker with ALTER SYSTEM KILL SESSION 'sid,serial#' IMMEDIATE, and write the SID, user and SQL_ID in the incident ticket.
