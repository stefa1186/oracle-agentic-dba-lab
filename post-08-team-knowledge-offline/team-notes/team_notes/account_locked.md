# Team note: application account locked

Team: DBA operations. Invented for the oracle-agentic-dba-lab; not a real company's procedure.

## When this applies
An application cannot connect because its database account is locked (ORA-28000), often after FAILED_LOGIN_ATTEMPTS was reached.

## What to do
Never unlock an application account before you know why it was locked: repeated failed logins can be an attack. Check the unified audit trail for the failed logins (source host, OS user, time). If they all come from the application's own servers, unlock with /opt/dba/bin/unlock_app.sh, which also records the unlock. If not, open a security ticket (SEC) and leave the account locked.
