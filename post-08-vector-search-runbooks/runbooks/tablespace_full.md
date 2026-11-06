# Runbook: tablespace full

Team: DBA operations. Invented for the oracle-agentic-dba-lab; not a real company's procedure.

## When this applies
A tablespace is above 90% of its maximum size, or sessions fail with ORA-01653, ORA-01654 or ORA-01688.

## What to do
Run /opt/dba/bin/ts_report.sh to see which segments grew. Add a new datafile rather than resizing an existing one beyond 32 GB. Datafiles follow the naming /u02/oradata/<SID>/<tablespace>_NN.dbf, with NN the next free number. Set AUTOEXTEND ON NEXT 1G MAXSIZE 32G on every new file.

## Exceptions
SYSTEM and SYSAUX are never extended without a change ticket (CHG) approved by the team lead. For SYSAUX, check first whether the AWR retention was changed: that is the usual cause.
