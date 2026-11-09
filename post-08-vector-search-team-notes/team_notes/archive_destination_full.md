# Team note: archive destination or fast recovery area filling up

Team: DBA operations. Invented for the oracle-agentic-dba-lab; not a real company's procedure.

## When this applies
The fast recovery area (FRA) or the archive log destination of a production database is above 90% full, or alert log entries show ORA-19809 or ORA-00257. If it reaches 100%, the database stops archiving and every session that commits will hang.

## What to do first
Never delete archived logs with rm or from the operating system: RMAN would still list them and the next backup fails. Run our archive backup script, which backs up and then deletes the archived logs that are already safe on tape: /opt/dba/bin/arch_backup.sh --delete-input. Check the result with: select percent_space_used from v$recovery_area_usage.

## If it keeps growing
If the FRA is above 97% after the script, page the on-call manager in the #dba-oncall channel and raise the incident to priority P2. As temporary relief only, you may increase DB_RECOVERY_FILE_DEST_SIZE by at most 20%, and only if the file system has room. Write the change in the incident ticket.
