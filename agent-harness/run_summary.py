#!/usr/bin/env python3
# =============================================================================
# run_summary.py
#
# One line per step of an agent run, from the harness log (events.jsonl):
# step, input tokens, tool, result (ok / ORA- code), and the SQL. Then the
# totals, the errors by code, and the statements the agent sent more than once.
# Answers "where did the steps go?" without reading the whole transcript.
#
#   python3 run_summary.py <run folder>      (the folder with events.jsonl)
#   python3 run_summary.py <run folder> --width 160
#   python3 run_summary.py <run folder> --step 1     full arguments and output of step 1
#
# Plain Python, no extra packages, no database access. Changes nothing.
# Oracle analogy: a quick TKPROF of one agent session.
# =============================================================================

# argparse: options. json: the harness log. re: ORA- codes. sys: exit codes.
import argparse
import json
import re
import sys
# signal: quiet exit when the output is piped into head/less.
import signal
# Counter: grouping errors and repeated statements.
from collections import Counter
# Path: the run folder.
from pathlib import Path

# An Oracle error in a tool's output, in the two forms SQLcl prints:
#   a SQL statement:  "Error report -", then "SQL Error: ORA-nnnnn: ..."
#   a PL/SQL block:   "ERROR at line n:", then "ORA-nnnnn: ..."
# Not an ORA code anywhere: SQLcl's connect message mentions "ORA-17274" in a
# hint to the model, and query RESULTS can hold ORA codes as data (the alert
# log's "ORA-00060: Deadlock detected", post 10). Neither is an error.
ORA = re.compile(r"(?:Error report -\s*\n(?:SQL Error: )?|ERROR at line \d+:\s*\n)(ORA-\d{5}):")


def one_line(text: str, width: int) -> str:
    """Collapse whitespace to single spaces and cut at 'width' characters."""
    flat = " ".join((text or "").split())
    return flat if len(flat) <= width else flat[: width - 3] + "..."


def result_of(output: str) -> str:
    """'ok' for a result without an Oracle error, otherwise the first ORA- code."""
    # A harness-level refusal (tool not allowed, rejected, bad JSON).
    if (output or "").startswith("TOOL ERROR"):
        return "TOOL ERROR"
    match = ORA.search(output or "")
    # Report the code alone.
    return match.group(1) if match else "ok"


def main() -> int:
    """Read the log, print the per-step lines and the totals."""
    # Piping the output into "head" or "less" should end quietly, not with a traceback.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    p = argparse.ArgumentParser(description="Summarise an agent run step by step.")
    p.add_argument("run_dir", help="Run folder (contains events.jsonl)")
    p.add_argument("--width", type=int, default=110, help="Width of the SQL column (default 110)")
    p.add_argument("--step", type=int, help="Print the full arguments and output of this step, and exit")
    args = p.parse_args()

    # The harness log of the run.
    path = Path(args.run_dir) / "events.jsonl"
    if not path.is_file():
        sys.exit(f"ERROR: {path} not found: not a harness run folder.")
    events = [json.loads(line) for line in path.open(encoding="utf-8") if line.strip()]

    # --step N: everything about one step, unabridged, then stop.
    if args.step is not None:
        found = False
        for e in events:
            if e.get("step") != args.step:
                continue
            found = True
            if e.get("event") == "model_call":
                # What the model wrote at this step (often empty when it only calls a tool).
                print(f"--- model_call (tokens in {e.get('prompt_tokens')}, out {e.get('completion_tokens')})")
                if e.get("content"):
                    print(e["content"])
            elif e.get("event") == "tool_call":
                # The exact request and the full result SQLcl returned.
                print(f"--- tool_call {e.get('tool')}")
                print("arguments: " + json.dumps(e.get("arguments"), indent=2))
                print("output:\n" + (e.get("output") or ""))
        if not found:
            sys.exit(f"ERROR: no step {args.step} in this run.")
        return 0

    # Input tokens of each model call, by step.
    tokens = {e["step"]: e.get("prompt_tokens") for e in events if e.get("event") == "model_call"}
    # Every tool call, in order.
    calls = [e for e in events if e.get("event") == "tool_call"]

    # Header.
    print(f"{'STEP':>4} {'TOKENS IN':>9}  {'TOOL':<18} {'RESULT':<10} SQL / ARGUMENTS")
    for e in calls:
        arguments = e.get("arguments") or {}
        # For sql_run, the SQL; for other tools, their arguments as JSON (identity values left out).
        if isinstance(arguments, dict) and "sql" in arguments:
            what = arguments["sql"]
        else:
            shown = {k: v for k, v in arguments.items() if k not in ("model", "mcp_client")} if isinstance(arguments, dict) else arguments
            what = json.dumps(shown)
        step = e.get("step")
        print(f"{step:>4} {tokens.get(step) or '':>9}  {e.get('tool', ''):<18} "
              f"{result_of(e.get('output')):<10} {one_line(what, args.width)}")

    # ---- Totals -------------------------------------------------------------
    end = next((e for e in reversed(events) if e.get("event") == "run_end"), {})
    model_calls = sum(1 for e in events if e.get("event") == "model_call")
    print(f"\nModel calls: {model_calls}   Tool calls: {len(calls)}   "
          f"Tokens in/out: {end.get('prompt_tokens_total')}/{end.get('completion_tokens_total')}")
    # How the run ended: a final answer, one asked for at the step limit, or none.
    answer = (end.get("final_answer") or "").strip()
    if end.get("ended") == "final_on_limit":
        print("Ended with: a final answer ASKED FOR at the step limit (--final-on-limit), no tools")
    elif answer.startswith("[STOPPED"):
        print("Ended with: " + answer.splitlines()[0])
    else:
        print("Ended with: a final answer")

    # Errors by code.
    errors = Counter(result_of(e.get("output")) for e in calls)
    errors.pop("ok", None)
    if errors:
        print("\nErrors by code:")
        for code, n in errors.most_common():
            print(f"  {n:>3}  {code}")

    # Statements sent more than once (compared case- and whitespace-insensitively).
    sqls = Counter(" ".join(e["arguments"]["sql"].split()).upper().rstrip(";")
                   for e in calls if isinstance(e.get("arguments"), dict) and "sql" in e["arguments"])
    repeats = [(s, n) for s, n in sqls.most_common() if n > 1]
    if repeats:
        print("\nSent more than once:")
        for sql, n in repeats:
            print(f"  {n:>3}x  {one_line(sql, args.width)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
