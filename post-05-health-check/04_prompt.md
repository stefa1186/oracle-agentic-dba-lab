Please run a health check of this database, the way an experienced DBA would before a change freeze. Use the saved database connection named "agent".

Cover at least these areas:
- STORAGE: tablespaces, the recovery area
- OBJECTS: invalid objects, unusable indexes
- STATS: optimizer statistics
- SECURITY: privileged accounts, default passwords
- BACKUP: archiving, backups, redo logs and control files
- MEMORY: SGA and PGA

Rules:
- Read only: do not change anything in the database.
- Your account can read only some dictionary views. Start by checking which ones (ROLE_TAB_PRIVS), and plan with those. If a view fails with ORA-00942 or ORA-01031, don't try variants of it: note that you couldn't check it and move on.
- Base every finding on a query result you actually received. If you could not check something, say so, and say why.
- Report problems, not healthy areas.

End your answer with your findings, one per line, in exactly this format, and nothing after them:

FINDING | <STORAGE, OBJECTS, STATS, SECURITY, BACKUP or MEMORY> | <the object concerned, e.g. OWNER.NAME, or - if none> | <what is wrong, in a few words>
