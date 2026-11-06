# Runbook: Data Guard standby lag

Team: DBA operations. Invented for the oracle-agentic-dba-lab; not a real company's procedure.

## When this applies
The transport lag or apply lag of a physical standby (V$DATAGUARD_STATS) is above 15 minutes.

## What to do
Check V$ARCHIVE_DEST_STATUS on the primary for transport errors first. If transport is fine and only apply lags, restart managed recovery with /opt/dba/bin/dg_restart_apply.sh on the standby. Never use FAILOVER for a lag problem.

## Escalation
If the lag is above 60 minutes, open an incident with the Data Guard team, Team Saturn, and inform the business continuity manager: above 60 minutes our recovery point objective is broken.
