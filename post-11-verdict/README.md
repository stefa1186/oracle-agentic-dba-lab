# Post 11 – Verdict

Reruns every check of the series that involves no model, in one command, and
collects every agent run into one table from the harness logs, so the verdict
rests on evidence, not on memory.

Requires: posts 01-10, and every post's `99_cleanup.sh` done (the lab's
resting state: post 03's role, SQL Firewall enforcing, post 04's audit policy).

## Scripts (run as `oralab`)

| Script | Purpose |
|---|---|
| `01_guardrail_checks.sh` | Reruns the model-free checks of posts 01-04 and 09, each post's own script unchanged: the cage, SQLcl's restrict level, grants and SQL Firewall, the audit trail's tamper resistance and its FETCH FIRST blind spot, the firewall bypass. One line per check: its exit code and its own result line. Full output in `output/post-11-verdict/guardrails.txt`. Leaves the firewall enforcing |
| `02_collect_runs.sh [<label>=<folder> ...]` + `collect_runs.py` | Every agent run under one or more output folders, counted from `events.jsonl`: post, steps, tokens, how it ended, SQL statements, ORA- errors (the rule of `agent-harness/run_summary.py`), approvals. `runs.txt` (the narrow table it prints) and `runs.md` (every column, including model and provider per run) |

```bash
cd ~/oracle-agentic-dba-lab/post-11-verdict
./01_guardrail_checks.sh                      # about 3 minutes, no model
./02_collect_runs.sh                          # the runs under output/
# Two sets side by side, e.g. an archived set of runs and the current one:
./02_collect_runs.sh "article runs=$HOME/<archived output folder>" "rebuild=$HOME/oracle-agentic-dba-lab/output"
```

## Status

Run on 2026-11-05, after rebuilding the lab from scratch and rerunning posts
01-10 (full results in the article):

- **Guardrails:** 4 PASS (the cage, restrict level 4, grants + firewall,
  tamper attempts), 2 findings reproduced (the FETCH FIRST blind spot of the
  audit policy, post 04; the firewall bypass through SQLcl's own block, post 09).
- **Agent runs:** 25 for the articles (the `:free` endpoint) and 22 on the
  rebuild (the paid endpoint of the same model, BaseTen / DeepInfra /
  Venice), side by side. Every deterministic result was the same; the
  model's results varied (statement lists, answers at the step limit, a
  self-GRANT attempt in post 09, the root cause in post 10).

## Things to watch

- **Exit code 0 in the guardrail summary means "the script ran"**: read its
  result line. `06_test_fetch_first.sh` exits 1 while the blind spot exists;
  `06_firewall_bypass.sh` documents a bypass and exits 0.
- **The run table counts; it doesn't judge.** Whether an answer was right is
  in each post's scorecard and article.
- **Runs of older harness versions** have no `ended` field in `run_end`;
  `collect_runs.py` then derives it from the final answer, and shows a run
  with no `run_end` at all as crashed.
