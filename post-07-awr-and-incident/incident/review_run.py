#!/usr/bin/env python3
# =============================================================================
# review_run.py
#
# The timeline of one approval-mode run, from the harness log (events.jsonl):
# one line per tool call with the time since the start, the human's decision
# and how long it took, the result (ok / ORA- code / rejected) and the SQL.
# Then the totals: run time, time the model and the tools took, time the
# human took deciding, approved and rejected calls. Then the final answer.
#
# Usage: review_run.py <run folder>
# Plain Python, no extra packages. Changes nothing.
# =============================================================================

# datetime: timestamps. json: the log. pathlib: paths. re: ORA codes.
import datetime
import json
import pathlib
import re
# signal: quiet exit when piped into head/less. sys: arguments.
import signal
import sys

# An Oracle error in a tool's output, in the two forms SQLcl prints (the same
# rule as agent-harness/run_summary.py):
#   a SQL statement:  "Error report -", then "SQL Error: ORA-nnnnn: ..."
#   a PL/SQL block:   "ERROR at line n:", then "ORA-nnnnn: ..."
# Not an ORA code anywhere: in this post the DATA contains ORA codes (the alert
# log's "ORA-00060: Deadlock detected"), and a query that returns them did not
# fail. (The previous rule, "ORA- at the start of a line", missed the SQL form.)
ORA = re.compile(r"(?:Error report -\s*\n(?:SQL Error: )?|ERROR at line \d+:\s*\n)(ORA-\d{5}):")
# What the harness returns to the model for a rejected call.
REJECTED = "TOOL ERROR: the human operator rejected this tool call."


def short(text: str, width: int) -> str:
    """One-line excerpt of at most 'width' characters."""
    one = " ".join((text or "").split())
    return one if len(one) <= width else one[: width - 3] + "..."


def main() -> int:
    """Print the timeline, the totals and the answer of one run."""
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if len(sys.argv) != 2:
        sys.exit("usage: review_run.py <run folder>")
    events = [json.loads(l) for l in (pathlib.Path(sys.argv[1]) / "events.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    t0 = datetime.datetime.fromisoformat(events[0]["ts"])

    def since(e: dict) -> str:
        """mm:ss since the run started."""
        s = int((datetime.datetime.fromisoformat(e["ts"]) - t0).total_seconds())
        return f"{s // 60:02d}:{s % 60:02d}"

    print(f"{'T+':<6} {'DECISION':<15} {'RESULT':<10} CALL")
    pending = None
    approved = rejected = 0
    human = 0.0
    for e in events:
        if e.get("event") == "approval":
            # The decision comes just before its tool_call event.
            pending = e
            human += e.get("seconds", 0)
            approved += bool(e.get("approved"))
            rejected += not e.get("approved")
        elif e.get("event") == "tool_call":
            args = e.get("arguments") if isinstance(e.get("arguments"), dict) else {}
            call = args.get("sql") or f"[{e.get('tool')}]"
            output = e.get("output") or ""
            if output == REJECTED:
                result = "rejected"
            else:
                m = ORA.search(output)
                result = m.group(1) if m else "ok"
            decision = (f"{'yes' if pending.get('approved') else 'NO'} ({pending.get('seconds', 0):.0f} s)"
                        if pending else "-")
            print(f"{since(e):<6} {decision:<15} {result:<10} {short(call, 95)}")
            pending = None

    end = next((e for e in events if e.get("event") == "run_end"), {})
    total = (datetime.datetime.fromisoformat(events[-1]["ts"]) - t0).total_seconds()
    print(f"\nRun time:                {total / 60:.1f} min  (ended: {end.get('ended', '?')}, {end.get('steps', '?')} model calls)")
    print(f"Human deciding:          {human / 60:.1f} min")
    print(f"Model and tools:         {(total - human) / 60:.1f} min")
    print(f"Calls approved/rejected: {approved} / {rejected}")
    print("\n--- The agent's final answer")
    for line in (end.get("final_answer") or "").strip().splitlines():
        print(f"  | {line}")
    return 0


# Run main() only when executed, not when imported.
if __name__ == "__main__":
    sys.exit(main())
