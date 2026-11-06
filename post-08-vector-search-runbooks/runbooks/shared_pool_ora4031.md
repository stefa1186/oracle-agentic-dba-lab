# Runbook: ORA-04031, unable to allocate shared memory

Team: DBA operations. Invented for the oracle-agentic-dba-lab; not a real company's procedure.

## When this applies
Sessions fail with ORA-04031 ("unable to allocate ... bytes of shared memory"), usually in the shared pool or the large pool.

## What to do first
Collect the evidence before changing anything: run /opt/dba/bin/sga_snapshot.sh, which saves V$SGASTAT, V$SGA_RESIZE_OPS and the top SQL by sharable memory. Do not flush the shared pool in production during business hours (07:00 to 19:00): every session would hard parse at once.

## The usual causes
A sudden rise in hard parses from SQL with literals is the most common cause on our systems: check parse count (hard) in the snapshot. Increasing SHARED_POOL_SIZE needs a change ticket; it is not an incident action.
