You're the on-call DBA's assistant. It's 3am and I've just been paged: users of the shop application in FREEPDB1 say order entry has been frozen for a few minutes. Use the saved database connection named "agent".

Investigate, the way an experienced DBA would in the first 20 minutes of an incident:
- Start with the alert log (V$DIAG_ALERT_EXT): what errors appeared recently, and where they point (for example a trace file).
- Then look at what the sessions are doing now, and at recent session history (ASH).

Rules:
- Read only: change nothing. I approve every statement before it runs, and I'll reject anything I don't need.
- Your account can read only some views. Check which ones first (ROLE_TAB_PRIVS), and plan with those.
- Base every claim on a query result you actually received. If you couldn't check something, say so.

End your answer with these four parts:
ROOT CAUSE: <one or two sentences>
EVIDENCE: <the query results that support it, quoted>
FIX NOW: <what should be done right now to end the incident, as the exact statement or action; I will decide>
FIX LATER: <what should change so it doesn't happen again>
