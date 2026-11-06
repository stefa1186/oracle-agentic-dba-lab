# Post 07 – SQL tuning: an AI agent vs. SQL Tuning Advisor

The same slow query, tuned by the agent and by SQL Tuning Advisor. Every
suggestion is **measured**, never estimated: run as the application user,
after a shared pool flush, its real plan, buffer gets and time, and whether
a rewrite still returns the same result.

Requires: posts 01-04 (database, SQLcl, the agent harness). The agent's
account is **not** changed: the agent gets the query, its plan, the DDL and
the statistics attached to its prompt, and **no tools** (`--allow-tools NONE`).

## The slow query

```sql
select count(*) as orders, sum(amount) as total_amount
from   orders
where  trunc(order_date) = date '2025-03-15'
and    status = 'SHIPPED';
```

`ORDERS` has 1,000,000 rows (1,000 a day, each day's rows stored together),
an index on `ORDER_DATE`, fresh statistics. `TRUNC()` on the indexed column
keeps the optimizer from using the index. The best fix needs no new index (a
date range on `ORDER_DATE`); other fixes work too (a function-based index, a
SQL profile). That's what makes the comparison interesting.

## Licensing

Oracle's *Database Licensing Information User Manual* (26ai) lists the Tuning
Pack as **included for Oracle AI Database Free**. On Enterprise Edition it's
an extra-cost option that also requires the Diagnostics Pack. `01_setup.sh`
checks CONTROL_MANAGEMENT_PACK_ACCESS and prints the edition.

## Scripts (run as `oralab`, in order)

| Script | Purpose |
|---|---|
| `env.example` | Schema name, rows, runs per measurement, advisor time limit |
| `lib.sh` | Reuses posts 01-04 helpers; `measure_query` (the one way every query is measured) |
| `01_setup.sh` + `setup_schema.sql` | Tuning Pack check; application user `TUNE_LAB` (new random password in `~/.config/oralab/tune_lab_pwd`, mode 600), `ORDERS`, indexes, statistics |
| `query_original.sql` | The slow query |
| `02_measure.sh [query] [label]` + `parse_measure.py` | Runs a query 3 times as `TUNE_LAB`, keeps the last execution's actual plan (ALLSTATS LAST), prints buffers, time, plan, result |
| `03_context_pack.sh` + `context_pack.sql` | What the agent gets: query, plan, DDL, statistics (`context_pack.txt`) |
| `04_tuning_advisor.sh` + `tuning_advisor.sql` | SQL Tuning Advisor on the query's cursor: report (`advisor_report.txt`) and its script as fix lines (`advisor_fixes.txt`) |
| `05_prompt.md` | The agent's task, ending with `REWRITE \|` and `DDL \|` lines |
| `06_try_fix.sh advisor\|<file>.txt\|<run>` + `fix_lines.py` | Measures baseline, rewrite, indexes, profile; same result?; undoes every change. `try_<label>.txt` |
| `advisor_text_fixes.txt`, `dba_fixes.txt` (see `FIXES.md`) | Hand-written fix lines: the advisor's text-only advice translated into statements, and my own fix as a DBA |
| `99_cleanup.sh` | Drops the advisor task, any test profile, `TUNE_LAB`, the password file |

## Step by step

```bash
cd ~/oracle-agentic-dba-lab/post-07-sql-tuning
./01_setup.sh                  # a minute or two
./02_measure.sh                # the baseline
./03_context_pack.sh
./04_tuning_advisor.sh         # up to 2 minutes
./06_try_fix.sh advisor                  # its scripted actions (none, on 2026-11-05)
./06_try_fix.sh advisor_text_fixes.txt   # its text advice, translated by me
./06_try_fix.sh dba_fixes.txt            # my own fix

# The agent: three runs, the context pack attached, no tools.
cd ../agent-harness
./run_matrix.sh -r 3 ../post-07-sql-tuning/05_prompt.md -- \
    --attach ~/oracle-agentic-dba-lab/output/post-07-sql-tuning/context_pack.txt \
    --allow-tools NONE
cd ../post-07-sql-tuning

# Each run's suggestions, measured.
for run in ~/oracle-agentic-dba-lab/output/post-07-sql-tuning/*/*/run-*; do ./06_try_fix.sh "$run"; done

./99_cleanup.sh                # when done
```

## What 06_try_fix.sh runs, and what it doesn't

Suggestions are run automatically, so only what can be undone exactly, or
only reads, is accepted (`fix_lines.py`):

- **REWRITE:** one `SELECT` (or `WITH ... SELECT`), nothing that writes. Run
  as `TUNE_LAB`, which owns only its own table.
- **DDL:** `CREATE INDEX` on `TUNE_LAB.ORDERS` only. Each index is dropped
  right after its measurement (`DROP INDEX IF EXISTS`), and again on exit.
- **PROFILE:** only SQL Tuning Advisor's own task. Accepted as
  `POST07_PROFILE`, dropped right after, and again on exit.

Anything else is listed as "not tested", with the reason, and never run.

## Things to watch

- **Shared pool flush.** Every measurement flushes FREEPDB1's shared pool,
  so each change gets a fresh plan. Fine in this lab, never on a shared system.
- **Same result.** A rewrite that's faster but returns something else is a
  bug, not a tuning. `06` compares the rewrite's result with the original's.
- **Three runs.** The agent's advice may differ between runs (non-determinism,
  part 7's AI topic). `06` is run once per run folder.

## Observed on the lab (2026-11-05, nvidia/nemotron-3-ultra-550b-a55b:free)

All results equal the original's (200 orders, 26,987). Buffer gets, last of 3 runs:

| Case | Buffers |
|---|---|
| Baseline: full table scan | 6,667 |
| Rewrite to a date range (identical in all sources) | 1,006 |
| Advisor (translated): index on TRUNC(ORDER_DATE), query unchanged | 1,006 |
| DBA, agent runs 2 and 3: rewrite + index (ORDER_DATE, STATUS) | 207 |
| Agent run 1: rewrite + covering index (ORDER_DATE, STATUS, AMOUNT) | 8 |
| Any of these indexes without the rewrite (except the TRUNC one) | 6,667 (run 1's: 4,392, index fast full scan) |

- **SQL Tuning Advisor:** one Restructure SQL finding, exact, in one second;
  text only, its script had no actions.
- **The agent:** the same rewrite in all three runs, two different indexes;
  every prediction of the rewrite's effect wrong ("a few hundred" vs 1,006),
  because the clustering factor (999,998) and the STATUS filter after table
  access weren't taken into account.
- **Production:** only the function-based index helps the query as written;
  every other fix needs an application change.
