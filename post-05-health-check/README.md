# Post 05 – Health check: an AI agent vs. my checklist

Seeds problems I know are there (the answer key), runs my own checklist,
lets the agent run a health check with no hints about what was seeded, and
scores its findings against the checklist.

Requires: posts 01-04 (database, SQLcl, `AI_AGENT` with least privilege and
a SQL Firewall allow-list, the audit policy, agent harness).

## What changes for the agent, and why

A health check needs to see more than post 03's six views. The extra views
are listed in `health_check_views.txt`, one per line: **exactly what my own
checklist reads, no more**, so the comparison is fair. No AWR or ASH views.

SQL Firewall goes to **observe** mode: its allow-list was taught for post
03's job, and would block every health-check query. It still logs them.

Everything is reverted by `99_cleanup.sh`.

## Scripts (run as `oralab`, in order)

| Script | Purpose |
|---|---|
| `env.example` | Names (HC_SEED, HC_LEGACY, HC_SMALL), sizes, checklist thresholds, step limit |
| `lib.sh` | Reuses posts 01-04 helpers; runs this folder's SQL files with their settings |
| `health_check_views.txt` | The views added to the agent's role for this test |
| `01_prepare_agent.sh` | Widens the role, firewall to observe, checks the audit policy is on |
| `02_seed_known_problems.sh` + `seed_known_problems.sql` | The answer key: a near-full tablespace, stale (locked) statistics, an invalid view and procedure, an unusable index, a non-Oracle account with DBA. Saved as `answer_key.txt` |
| `03_dba_checklist.sh` + `dba_checklist.sql` | My checklist on the same database (13 checks, 6 categories). Saved as `checklist.txt`; fails if it misses a seeded problem |
| `04_prompt.md` | The agent's task: a health check, findings in a fixed one-line format |
| `05_score.sh [run]` + `score.py` | Pairs the agent's findings with the checklist's; writes `scorecard.md` with suggested marks |
| `06_judge_extras.sh` + `judge_extras.sql` | Read-only facts for judging the agent's findings that aren't on the checklist |
| `99_cleanup.sh` | Drops the seeded objects, narrows the role back to post 03, firewall to enforce |

## Step by step

```bash
cd ~/oracle-agentic-dba-lab/post-05-health-check
./01_prepare_agent.sh
./02_seed_known_problems.sh
./03_dba_checklist.sh

# The agent: a health check needs more steps than the harness default of 20.
cd ../agent-harness
./run_matrix.sh ../post-05-health-check/04_prompt.md -- --max-steps 40 --final-on-limit
cd ../post-05-health-check

./05_score.sh                                          # the latest run

# Where the steps went, and what the database recorded (pass the run folder
# printed by run_matrix.sh as "Run complete: ..."):
RUN=$(ls -1d ~/oracle-agentic-dba-lab/output/post-05-health-check/*/*/run-* | sort | tail -1)
python3 ../agent-harness/run_summary.py "$RUN"
../post-04-auditing-the-agent/03_audit_trail.sh "$RUN"

./99_cleanup.sh                                        # when done
```

With several models in one matrix, score each run folder:
`./05_score.sh ~/oracle-agentic-dba-lab/output/post-05-health-check/<time>/<model>/run-1`.

## How scoring works

Both sides report findings in the same format:

```
FINDING | <STORAGE, OBJECTS, STATS, SECURITY, BACKUP or MEMORY> | <object> | <what is wrong>
```

`score.py` pairs an agent finding with a checklist finding when the
category is the same and the checklist's object name appears in the agent's
line (or the agent named the object without its owner). It suggests ✅ for a
pair and ❌ for a checklist finding with no pair, and lists the agent's other
findings for me to check. **The suggestions are mechanical; the final marks
are mine**, edited in `scorecard.md`:

- ✅ found it, and explained it correctly
- ⚠️ found it, but the explanation was wrong or shallow
- ❌ missed it
- 👻 reported a problem that doesn't exist
- ➖ true, but not a problem: noise a DBA would filter out (agent's extra findings only)

An agent finding that isn't on my checklist is not automatically 👻: it may
be real and my checklist may not cover it. Each one gets checked against the
database before it's marked: `06_judge_extras.sh` prints the facts needed
(room to grow per tablespace, whether DBA or OPEN accounts can log in at
all, memory parameters in the CDB vs. the PDB, where archived logs go,
missing statistics by kind of schema).

## The checklist (dba_checklist.sql)

| Category | Checks |
|---|---|
| STORAGE | Tablespaces ≥ 85% of maximum size; recovery area ≥ 80% net of reclaimable |
| OBJECTS | Invalid objects in application schemas; invalid objects in Oracle schemas (per owner); unusable indexes |
| STATS | Stale or missing table statistics in application schemas |
| SECURITY | Application accounts with DBA; open accounts with default passwords |
| BACKUP | NOARCHIVELOG; no successful RMAN backup in 7 days; single-member redo groups; fewer than 2 control files |
| MEMORY | PGA over-allocation since startup |

Thresholds are in `env.example`. Expect findings I didn't seed: a lab
database has never been backed up, and its redo logs and control files
are probably not multiplexed. They count: a health check should find them.

## Things to watch

- **Locked statistics.** The seed locks HC_ORDERS's statistics, so the
  nightly statistics job can't make the problem disappear between seeding
  and the agent's run.
- **Schema-only accounts.** HC_SEED and HC_LEGACY are created with NO
  AUTHENTICATION: nobody can log in as them, including the one with DBA.
- **Rerunning the seed** drops and recreates everything, so the answer key
  always describes the current state.
- **MAX_STEPS.** The first run (2026-11-05, without `--final-on-limit` and
  without the ROLE_TAB_PRIVS rule in the prompt) used all 40 steps and wrote
  no answer: 14 steps went on password profiles, 8 of them ORA-00942 on views
  it can't read (DBA_PROFILES, USER_PROFILES, CDB_PROFILES, V$PWFILE_USERS).
  It was on its last category (MEMORY) when it stopped. Hence the prompt rule
  and `--final-on-limit`, which asks once, with no tools, for the answer from
  what it has. `run_summary.py` shows whether a run ended that way.

## Observed on the lab (2026-11-05, nvidia/nemotron-3-ultra-550b-a55b:free)

- **Run 1** (no ROLE_TAB_PRIVS rule, no `--final-on-limit`): 40 steps, no
  answer; 12 x ORA-00942, 14 steps on password profiles; 729,141 tokens in.
- **Run 2** (both): ROLE_TAB_PRIVS first, 2 errors in 40 steps (an earlier version of
  `run_summary.py` counted SQLcl's ORA-17274 connect hint as a third); answer asked
  for at step 41; 351,298 tokens in.
- **Score:** all 10 checklist findings found (the 3 redo groups as one line,
  paired by hand): 9 ✅, 1 ⚠️ (stale statistics not seen as locked).
- **Extra findings (11):** 1 real and missing from my checklist (no recovery
  area, archived logs in `$ORACLE_HOME/dbs/arch`), 5 ➖, 5 👻. All five 👻
  are a correct number read without its context: free space without
  autoextend, OPEN without AUTHENTICATION_TYPE NONE, the PDB's SGA_TARGET (0)
  read as the instance's (1536M).
- **ORA-17274 on connect is not an error:** it's in SQLcl's connect message,
  a hint addressed to the model. `run_summary.py` now counts only
  `ORA-nnnnn:` (with the colon) as an error.
- **Candidates for the checklist:** archive destination inside the Oracle
  home with no recovery area; password profile limits.
