#!/usr/bin/env python3
# =============================================================================
# compare.py  (run by 06_compare.sh)
#
# Compares the cloud model and the local models, from the harness logs:
#
#   compare.py select <runs folder> <prompt's folder name>
#       The runs of one test (the prompt from post-02-... or post-08-...): the
#       newest run of each model and attached file, one run folder per line.
#       Older runs are ignored.
#   compare.py inventory <answer key> <run folders...>
#       Test A: post 02's four questions. Per model: the answer key's markers
#       (from the database itself) found in the answer, the statements, the
#       errors, the statements outside the SQL Firewall allow-list
#       (violations.jsonl, exported by 06_compare.sh), and the run's end.
#   compare.py speed <run folders...>
#       Per model: runs, model calls (and failed ones), time in model calls,
#       tokens read and written, tokens written per second.
#   Both tables also show each model's thinking setting (REASONING_EFFORT).
#   compare.py answers <run folders...>
#       The final answer of each run, as written.
#
# Plain Python, no extra packages. Read-only: changes nothing.
# =============================================================================

# datetime: run times. json: the logs. pathlib: paths. re: markers.
import datetime
import json
import pathlib
import re
# signal: quiet exit when piped into head/less. sys: arguments, import path.
import signal
import sys

# The harness's own classification of a tool result ("ok", "TOOL ERROR" or the
# first ORA- code, as SQLcl prints it after "Error report -" or "ERROR at line
# n:"), so this table counts errors exactly as run_summary.py and post 11 do.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "agent-harness"))
from run_summary import result_of  # noqa: E402  (after the path is set)


def mentions(answer: str, text: str) -> bool:
    """True if the answer names this text as a whole word, ignoring case.
    "Whole" as an Oracle identifier: no letter, digit, _, $ or # right before
    or after it, so AI_AGENT is not found inside AI_AGENT_READ, and 23.26.3 is
    found in 23.26.3.0.0."""
    edge = r"[A-Za-z0-9_$#]"
    return re.search(rf"(?<!{edge}){re.escape(text)}(?!{edge})", answer, re.IGNORECASE) is not None


def events_of(run: pathlib.Path) -> list[dict]:
    """The run's events, one dict per line of events.jsonl."""
    return [json.loads(line) for line in (run / "events.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]


def first(events: list[dict], kind: str) -> dict:
    """The first event of a kind, or an empty dict."""
    return next((e for e in events if e.get("event") == kind), {})


def last(events: list[dict], kind: str) -> dict:
    """The last event of a kind, or an empty dict."""
    return next((e for e in reversed(events) if e.get("event") == kind), {})


def thinking(start: dict) -> str:
    """The run's thinking setting (REASONING_EFFORT in run_start): "none",
    "low", ..., or "default" when nothing was sent (the server decided)."""
    return start.get("reasoning_effort") or "default"


def seconds_between(a: dict, b: dict) -> float:
    """Seconds from event a to event b (0 if either has no timestamp)."""
    if not a.get("ts") or not b.get("ts"):
        return 0.0
    return (datetime.datetime.fromisoformat(b["ts"]) - datetime.datetime.fromisoformat(a["ts"])).total_seconds()


def mmss(seconds: float) -> str:
    """Seconds as m:ss."""
    s = int(round(seconds))
    return f"{s // 60}:{s % 60:02d}"


def select(folder: str, prompt_dir: str) -> int:
    """Print the newest run of each model (and attached file) for one prompt."""
    newest: dict[tuple, pathlib.Path] = {}
    # Run folders are <timestamp>/<provider>_<model>/run-N: sorted paths are in time order.
    for ev_file in sorted(pathlib.Path(folder).glob("*/*/run-*/events.jsonl")):
        start = first(events_of(ev_file.parent), "run_start")
        # Only the runs of this test: its prompt file's folder.
        if pathlib.Path(start.get("prompt_file", "")).parent.name != prompt_dir:
            continue
        attached = tuple(pathlib.Path(a["file"]).name for a in start.get("attached") or [])
        # Later runs replace earlier ones with the same key.
        newest[(start.get("model"), attached)] = ev_file.parent
    for run in sorted(newest.values()):
        print(run)
    return 0


def inventory(key_file: str, runs: list[str]) -> int:
    """Test A: one line per model, then the markers each one missed."""
    # MARK|<kind>|<text>: what a correct answer contains.
    marks = [line.rstrip("\n").split("|", 2)[1:] for line in open(key_file, encoding="utf-8") if line.startswith("MARK|")]
    print("| Model | Thinking | Markers found | SQL statements | ORA- errors | Outside the allow-list | Steps | Run time | Ended |")
    print("|---|---|---|---|---|---|---|---|---|")
    missed: dict[str, list[str]] = {}
    for r in runs:
        run = pathlib.Path(r)
        ev = events_of(run)
        start, end = first(ev, "run_start"), last(ev, "run_end")
        answer = end.get("final_answer") or ""
        # Markers: whole-word, case-insensitive search in the final answer (mentions()).
        found = [f"{k}:{v}" for k, v in marks if mentions(answer, v)]
        missed[start.get("model", "?")] = [f"{k}: {v}" for k, v in marks if not mentions(answer, v)]
        # The statements the model sent, and how many came back with an ORA- error.
        calls = [e for e in ev if e.get("event") == "tool_call" and isinstance(e.get("arguments"), dict) and e["arguments"].get("sql")]
        errors = sum(1 for e in calls if result_of(e.get("output") or "").startswith("ORA-"))
        # Statements SQL Firewall logged as outside its allow-list (06_compare.sh exports them).
        vfile = run / "violations.jsonl"
        outside = sum(1 for line in vfile.read_text(encoding="utf-8").splitlines() if line.startswith("{")) if vfile.exists() else "?"
        print(f"| {start.get('model', '?')} | {thinking(start)} | {len(found)} of {len(marks)} | {len(calls)} | {errors} | {outside} "
              f"| {end.get('steps', '?')} | {mmss(seconds_between(start, end))} | {end.get('ended', '?')} |")
    print()
    for model, items in missed.items():
        print(f"- {model} missed: {', '.join(items) if items else 'nothing'}")
    return 0


def speed(runs: list[str]) -> int:
    """Per model: runs, time spent in model calls, tokens in and out, tokens per second."""
    per: dict[str, dict] = {}
    for r in runs:
        ev = events_of(pathlib.Path(r))
        start, end = first(ev, "run_start"), last(ev, "run_end")
        m = per.setdefault(start.get("model", "?"), {"runs": 0, "secs": 0.0, "out": 0, "in": 0, "calls": 0,
                                                     "failed": 0, "thinking": thinking(start)})
        m["runs"] += 1
        # Time inside model calls only (not SQL, not SQLcl's start-up).
        model_calls = [e for e in ev if e.get("event") == "model_call"]
        m["calls"] += len(model_calls)
        # Calls that got no answer (timeout, endpoint error): no tokens, so
        # their time is not in the speed, but they are counted.
        m["failed"] += sum(1 for e in ev if e.get("event") == "model_error")
        m["secs"] += sum(float(e.get("seconds") or 0) for e in model_calls)
        # Tokens the model read (the prompt, re-sent at every step) and wrote.
        m["in"] += int(end.get("prompt_tokens_total") or 0)
        m["out"] += int(end.get("completion_tokens_total") or 0)
    print("| Model | Thinking | Runs | Model calls | Failed calls | Time in model calls | Tokens read | Tokens written | Tokens written per second |")
    print("|---|---|---|---|---|---|---|---|---|")
    for model, m in per.items():
        rate = f"{m['out'] / m['secs']:.1f}" if m["secs"] else "?"
        print(f"| {model} | {m['thinking']} | {m['runs']} | {m['calls']} | {m['failed']} | {mmss(m['secs'])} "
              f"| {m['in']:,} | {m['out']:,} | {rate} |")
    return 0


def answers(runs: list[str]) -> int:
    """Each run's final answer, as written, with what it was given."""
    for r in runs:
        ev = events_of(pathlib.Path(r))
        start, end = first(ev, "run_start"), last(ev, "run_end")
        attached = ", ".join(pathlib.Path(a["file"]).name for a in start.get("attached") or []) or "-"
        print(f"\n==> {start.get('model', '?')} | attached: {attached} | ended: {end.get('ended', '?')}")
        for line in (end.get("final_answer") or "(no answer)").strip().splitlines():
            print(f"    | {line}")
    return 0


def main() -> int:
    """Dispatch on the first argument."""
    # Piping into head/less should end quietly.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if len(sys.argv) == 4 and sys.argv[1] == "select":
        return select(sys.argv[2], sys.argv[3])
    if len(sys.argv) >= 4 and sys.argv[1] == "inventory":
        return inventory(sys.argv[2], sys.argv[3:])
    if len(sys.argv) >= 3 and sys.argv[1] == "speed":
        return speed(sys.argv[2:])
    if len(sys.argv) >= 3 and sys.argv[1] == "answers":
        return answers(sys.argv[2:])
    sys.exit("usage: compare.py select <folder> <prompt dir> | inventory <key> <runs...> | speed <runs...> | answers <runs...>")


# Run main() only when executed, not when imported.
if __name__ == "__main__":
    sys.exit(main())
