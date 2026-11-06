# Post 10 – From alert log to root-cause hypothesis

A realistic incident, and the agent investigates it read-only, with a human
approving every statement before it runs.

**The incident:** the shop application's order entry and invoicing batch take
the same two rows (STOCK item 42, ORDERS 1001) in opposite order: a deadlock.
Oracle rolls back one statement with ORA-00060 (alert log + trace file).
The application catches the error and leaves its transaction open, so item 42
stays locked, and every user who orders it waits: "the shop is frozen".

Requires: posts 03 and 04. Run only in the isolated lab.

## Scripts (in order)

| Script | Purpose |
|---|---|
| `01_prepare_agent.sh` | Role = post 03 views + `diag_views.txt` (alert log, trace files, sessions, locks, ASH, SQL, object names); firewall to observe; audit check |
| `02_create_incident.sh` | SHOP_APP and its tables (`setup_shop.sql`), then the deadlock and the pile-up (`session_*.sql`, run by `incident_session.sh` in the background; order entry is held idle with its transaction open, then `session_order_entry_end.sql`); checks the state |
| `03_prompt.md` | The prompt |
| `03_run_agent.sh` | The agent run in approval mode (`--confirm`): interactive, from a terminal |
| `04_dba_investigation.sh` | My own investigation, as SYSDBA (`dba_investigation.sql`) |
| `05_review_run.sh [<run>]` | Timeline of the run with my decisions and the time each took (`review_run.py`), then the audit trail |
| `99_cleanup.sh` | Ends the incident, drops SHOP_APP, role back to post 03, firewall back to enforcing |

```bash
./01_prepare_agent.sh
./02_create_incident.sh
./03_run_agent.sh          # answer y/N at every step
./04_dba_investigation.sh
./05_review_run.sh
./99_cleanup.sh
```

The incident lasts `INCIDENT_MINUTES` (60) unless `99_cleanup.sh` ends it
sooner; `02_create_incident.sh` starts a fresh, identical one whenever needed.
The application user's password exists only for one run of
`02_create_incident.sh`, travels through stdin only, and the account is
locked as soon as its sessions are connected.

During the run, reject at least one call you wouldn't run yourself (a full
scan of a trace file, say), to see what the agent does with a "no".

## Status

Run on the lab on 2026-11-05 (nvidia/nemotron-3-ultra-550b-a55b, the paid
endpoint of the series' model; the :free one was down); full results in
the article.

- **First run (discarded as a test, kept as a lesson):** a perfect root cause,
  because the incident's PL/SQL blocks had comments inside them ("4. The bug:
  ..."), and comments are part of the SQL text in V$SQL, which the agent read.
  The blocker also slept inside the exception handler (ACTIVE, "PL/SQL lock
  timer"). Fixed: no comments inside any block, and the blocker is held idle
  by `incident_session.sh`, with its transaction open, like a pooled connection.
- **Second run:** 20 tool calls in 5.4 minutes, 16 approved, 4 rejected (all
  useless repeats), ended at MAX_STEPS (`--final-on-limit`); 2.6 of the 5.4
  minutes were the approvals.
- Right: the blocker (idle, holding STOCK item 42), the four waiters, and the
  FIX NOW (KILL SESSION of the blocker; run as SYSDBA, every shop session
  finished within 10 s).
- Wrong: the root cause ("inconsistent lock ordering": the deadlock, not the
  transaction left open after ORA-00060), so FIX LATER fixes the wrong thing;
  "parent (ORDERS) before child (STOCK)" reversed; a unique index on the
  primary key "if missing".
- 9 steps lost in ASH: SAMPLE_TIME (TIMESTAMP, UTC) compared with
  SYSTIMESTAMP in a session whose time zone is the host's (Europe/Berlin): 0
  rows for "the last 30 minutes"; then `05-NOV-26` from SYSTIMESTAMP read as
  2026-11-26, five times. A filter relative to MAX(sample_time) worked.
- The audit trail had 9 of the 15 statements that ran: the 6 missing all had
  FETCH FIRST (post 04, `06_test_fetch_first.sh`).
- The model gave no reason before any call, although the system prompt asks
  for one: every approval was on the SQL alone, and a rejection carries no
  reason back to the model.

## Things to watch

- **ASH and time zones.** SAMPLE_TIME has no time zone; compare it with
  SYSDATE, or use SAMPLE_TIME_UTC, never with SYSTIMESTAMP. SQLcl's
  sessions take the host's time zone, not the database's.
- **What the agent can read is input.** Comments inside PL/SQL blocks are in
  V$SQL; module and action names are in V$SESSION; the alert log records a
  KILL SESSION with the SQL_ID behind it. Keep the answer key out of all of them.
- **A held session after cleanup.** `99_cleanup.sh` and `02_create_incident.sh`
  stop the incident's client processes too (`stop_incident_clients`, by the
  process groups in `sessions/*.pid`).
- **SQL*Plus DEFINE with spaces.** A value with a space must be quoted
  (`define start_utc = "2026-11-05 21:25:36"`): unquoted, only the first
  word is kept. `04_dba_investigation.sh` quotes it.
