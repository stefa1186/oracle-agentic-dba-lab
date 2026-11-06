#!/usr/bin/env python3
# =============================================================================
# collect_runs.py  (used by 02_collect_runs.sh, not run by hand)
#
# One line per agent run, from the harness's own log (events.jsonl) of every
# run under one or more output folders: which post, which model and provider,
# how many steps and tokens, how it ended, how many SQL statements, how many
# of them failed (by ORA- code), and in approval mode how many calls the human
# approved and rejected. Nothing is judged here: every number is counted from
# the log, the same way agent-harness/run_summary.py counts it.
#
# Usage: collect_runs.py [--format md|text] <label>=<output folder> [...]
#   md (default): one Markdown table per label, every column, then the totals
#   text:         a narrow plain-text table per label (for a terminal or a
#                 post), the models and providers once per label, the totals
# =============================================================================

# collections.Counter: counting how runs ended and which ORA- codes appeared.
from collections import Counter
# json: one event per line in events.jsonl.
import json
# pathlib: finding the run folders.
import pathlib
# sys: the arguments and the import path.
import sys

# The harness's own classification of a tool result ("ok", "TOOL ERROR" or the
# first ORA- code), so this table counts exactly what run_summary.py counts.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "agent-harness"))
from run_summary import result_of


def ended_of(end: dict) -> str:
    """How the run ended. Logs from before 2026-11-05 have a run_end without the
    "ended" field: then the final answer tells (the harness writes a fixed text
    when it stops at MAX_STEPS). No run_end at all: the run crashed."""
    if not end:
        return "no run_end (crashed)"
    if end.get("ended"):
        return end["ended"]
    return "max_steps" if (end.get("final_answer") or "").startswith("[STOPPED: reached MAX_STEPS") else "answer"


def one_run(events_file: pathlib.Path, root: pathlib.Path) -> dict:
    """Everything this summary needs from one run's events.jsonl."""
    events = [json.loads(line) for line in events_file.open(encoding="utf-8") if line.strip()]
    start = next((e for e in events if e.get("event") == "run_start"), {})
    end = next((e for e in events if e.get("event") == "run_end"), {})
    calls = [e for e in events if e.get("event") == "model_call"]
    tools = [e for e in events if e.get("event") == "tool_call"]
    sql = [e for e in tools if e.get("tool") == "sql_run"]
    approvals = [e for e in events if e.get("event") == "approval"]
    # ORA- codes in the results of the agent's SQL; a rejected call is "TOOL ERROR", not counted here.
    codes = Counter(r for r in (result_of(e.get("output")) for e in sql) if r.startswith("ORA-"))
    # The folder layout: <root>/<post>/<timestamp>/<provider_model>/run-<n>/events.jsonl
    rel = events_file.parent.relative_to(root).parts
    providers = sorted({c.get("provider_returned") for c in calls if c.get("provider_returned")})
    return {
        "post": rel[0],
        "stamp": rel[1],
        "run": rel[-1],
        "model": start.get("model", "?"),
        "providers": ", ".join(providers) or "-",
        "tools": "none" if not start.get("tools") else str(len(start.get("tools"))),
        "steps": end.get("steps", len(calls)),
        "tokens_in": end.get("prompt_tokens_total", sum(c.get("prompt_tokens") or 0 for c in calls)),
        "tokens_out": end.get("completion_tokens_total", sum(c.get("completion_tokens") or 0 for c in calls)),
        "ended": ended_of(end),
        "sql": len(sql),
        "errors": ", ".join(f"{n} {c}" for c, n in codes.most_common()) or "-",
        "approved": sum(1 for a in approvals if a.get("approved")),
        "rejected": sum(1 for a in approvals if not a.get("approved")),
        "confirm": bool(start.get("confirm")),
    }


def table(runs: list[dict]) -> list[str]:
    """The Markdown table of one label's runs."""
    out = ["| Post | Run | Model | Answered by | Tools | Steps | Tokens in / out | Ended | SQL | ORA- errors | Approved / rejected |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in runs:
        appr = f"{r['approved']} / {r['rejected']}" if r["confirm"] else "-"
        out.append(f"| {r['post']} | {r['stamp']} {r['run']} | `{r['model']}` | {r['providers']} | {r['tools']} | "
                   f"{r['steps']} | {r['tokens_in']:,} / {r['tokens_out']:,} | {r['ended']} | {r['sql']} | {r['errors']} | {appr} |")
    return out


def text_table(label: str, runs: list[dict]) -> list[str]:
    """The narrow plain-text version: one line per run, the models once."""
    models = ", ".join(sorted({r["model"] for r in runs}))
    providers = ", ".join(sorted({p for r in runs for p in r["providers"].split(", ") if p != "-"})) or "not logged"
    out = [f"{label}: {len(runs)} runs",
           f"  model(s):    {models}",
           f"  answered by: {providers}",
           f"  {'POST':<5}{'RUN':<23}{'STEPS':>5}{'TOKENS IN':>11}  {'ENDED':<21}{'SQL':>4}  {'ORA- ERRORS':<41}{'APPROVED/REJ':>12}"]
    for r in runs:
        appr = f"{r['approved']}/{r['rejected']}" if r["confirm"] else "-"
        post = r["post"].split("-")[1]
        out.append(f"  {post:<5}{r['stamp'] + ' ' + r['run']:<23}{r['steps']:>5}{r['tokens_in']:>11,}  "
                   f"{r['ended'][:20]:<21}{r['sql']:>4}  {r['errors'][:40]:<41}{appr:>12}")
    return out


def main() -> int:
    """Read every label=folder argument, print one section per label."""
    args = sys.argv[1:]
    # The output format: Markdown by default, or plain text.
    fmt = "md"
    if args[:1] == ["--format"] and len(args) >= 2:
        fmt, args = args[1], args[2:]
    if fmt not in ("md", "text") or not args:
        sys.exit("usage: collect_runs.py [--format md|text] <label>=<output folder> [...]")
    for arg in args:
        label, _, folder = arg.partition("=")
        root = pathlib.Path(folder).expanduser().resolve()
        # Every harness run: a run-<n> folder holding events.jsonl, in time order.
        files = sorted(root.glob("post-*/*/*/run-*/events.jsonl"), key=lambda p: str(p.relative_to(root)))
        runs = [one_run(f, root) for f in files]
        ended = Counter(r["ended"] for r in runs)
        if fmt == "md":
            print(f"## {label}: {len(runs)} agent runs ({root})\n")
            print("\n".join(table(runs)))
            print("")
        else:
            print("\n".join(text_table(label, runs)))
        print("  Ended:  " + ", ".join(f"{n} {k}" for k, n in ended.most_common()))
        print(f"  Tokens: {sum(r['tokens_in'] for r in runs):,} in, {sum(r['tokens_out'] for r in runs):,} out\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
