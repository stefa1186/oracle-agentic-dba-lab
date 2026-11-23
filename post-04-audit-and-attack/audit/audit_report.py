#!/usr/bin/env python3
# =============================================================================
# audit_report.py
#
# Reads the database's audit records for one agent run (JSON lines, produced by
# 03_audit_trail.sh / 04_compare.sh / 05_test_tamper.sh) and either:
#   --mode show     summarises them and lists the AGENT's statements (time,
#                   action, return code, model, SQL); --all lists every record
#   --mode compare  compares them with the harness's own log of the run
#                   (events.jsonl): which of the agent's statements the
#                   database recorded, which it didn't, and what else it
#                   recorded that the agent never mentioned
#
# How the agent's statements are recognised: SQLcl's MCP server inserts a
# comment "/* LLM in use is <model> */" into every statement it runs for the
# model (with the model ID the harness fills in). Everything else in the
# window is SQLcl's own housekeeping, or logon/logoff.
#
# Plain Python, no extra packages. Changes nothing.
# Oracle analogy: reconciling the application's log with the redo, line by line.
# =============================================================================

# argparse: command-line options. json: the audit export and the harness log.
import argparse
import json
# re: SQL comments and the model tag.
import re
# signal: quiet exit when the output is piped into head/less.
import signal
# sys: output and exit codes.
import sys
# Counter: grouping records by action.
from collections import Counter

# The tag SQLcl puts in every statement it runs on behalf of the model.
MODEL_TAG = re.compile(r"/\*\s*LLM in use is\s*(.*?)\s*\*/", re.IGNORECASE | re.DOTALL)
# Any SQL block comment.
SQL_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
# The export cuts SQL text at this many characters (see fetch_audit_jsonl).
EXPORT_SQL_LIMIT = 1500


# Control characters other than tab/newline/carriage return. The audit trail
# stores the agent's SQL with a trailing NUL (\x00), observed on the lab; the
# harness's copy has none, so they must go before comparing.
CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def norm(sql: str) -> str:
    """Normalise SQL for comparison: control characters (e.g. a trailing NUL)
    and comments (including SQLcl's model tag) removed, one line, single
    spaces, upper case, no trailing ';'."""
    clean = CONTROL_CHARS.sub(" ", sql or "")
    no_comments = SQL_COMMENT.sub(" ", clean)
    return " ".join(no_comments.split()).rstrip(";").strip().upper()


def model_of(row: dict) -> str:
    """The model named in SQLcl's tag inside the SQL text, or '' if none."""
    match = MODEL_TAG.search(row.get("SQL_TEXT") or "")
    return match.group(1) if match else ""


def is_agent(row: dict, model: str | None = None) -> bool:
    """True for statements SQLcl ran on behalf of the model (they carry the tag).
    With `model` given (the run's model, from its events.jsonl), only that
    model's tag counts: a statement tagged with another model, or with the
    replay's "replay (no model)", came from another client or run that
    happened to fall inside the time window."""
    tag = model_of(row)
    return bool(tag) and (model is None or tag == model)


def run_model(events_path: str | None) -> str | None:
    """The model ID of the run (its run_start event), or None without a log."""
    if not events_path:
        return None
    for line in open(events_path, encoding="utf-8"):
        if line.strip():
            event = json.loads(line)
            if event.get("event") == "run_start":
                return event.get("model")
    return None


def rc_label(rc: str | None) -> str:
    """'ok' for return code 0, otherwise the Oracle error, e.g. ORA-02004."""
    return "ok" if rc in (None, "", "0") else f"ORA-{int(rc):05d}"


def short(text: str, width: int) -> str:
    """One-line excerpt of at most 'width' characters."""
    one = " ".join((text or "").split())
    return one if len(one) <= width else one[: width - 3] + "..."


def read_audit(path: str) -> list[dict]:
    """Read the audit export: one JSON object per line (built by the database).
    Lines that are not JSON objects (blank lines, SQL*Plus messages) are skipped,
    but if NOTHING could be read from a non-empty export, the raw output is
    shown and the script stops, instead of silently reporting empty records."""
    rows, other = [], []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            text = line.strip()
            if text.startswith("{"):
                try:
                    # strict=False accepts raw control characters (e.g. a tab)
                    # inside strings, so one stray character can't break the report.
                    rows.append(json.loads(text, strict=False))
                except json.JSONDecodeError as exc:
                    # Keep going, but say which line could not be read.
                    print(f"WARNING: skipped an unreadable audit line ({exc}): {text[:120]}", file=sys.stderr)
            elif text:
                other.append(text)
    if not rows and other:
        print("ERROR: no audit records could be read. First lines of the export:", file=sys.stderr)
        for text in other[:10]:
            print(f"  {text}", file=sys.stderr)
        sys.exit(2)
    return rows


def summary(rows: list[dict], model: str | None = None) -> None:
    """Counts: the agent's statements vs other clients' vs SQLcl housekeeping
    vs logon/logoff."""
    agent = [r for r in rows if is_agent(r, model)]
    # Tagged, but by another model or the replay: not this run's agent.
    other = [r for r in rows if model_of(r) and not is_agent(r, model)]
    sessions = [r for r in rows if r.get("ACTION_NAME") in ("LOGON", "LOGOFF")]
    housekeeping = len(rows) - len(agent) - len(other) - len(sessions)
    print(f"{len(rows)} audit records:")
    print(f"  {len(agent):>4}  statements the agent sent (tagged by SQLcl with the model)")
    if other:
        names = ", ".join(sorted({model_of(r) for r in other}))
        print(f"  {len(other):>4}  statements of another client in the window (tagged: {names})")
    print(f"  {housekeeping:>4}  SQLcl housekeeping (session setup, its log-table checks, commits)")
    print(f"  {len(sessions):>4}  logon / logoff")


def show(rows: list[dict], show_all: bool, model: str | None = None) -> None:
    """Summary, then one line per record: the agent's only, or all with --all."""
    summary(rows, model)
    listed = rows if show_all else [r for r in rows if is_agent(r, model) or r.get("ACTION_NAME") in ("LOGON", "LOGOFF")]
    print(f"\n{'TIME (UTC)':<13} {'ACTION':<10} {'RESULT':<10} {'MODEL':<26} SQL")
    for r in listed:
        sql = SQL_COMMENT.sub(" ", r.get("SQL_TEXT") or "")
        print(f"{(r.get('TS') or '')[11:23]:<13} {short(r.get('ACTION_NAME'), 10):<10} "
              f"{rc_label(r.get('RETURN_CODE')):<10} {short(model_of(r), 26):<26} {short(sql, 70)}")
    if not show_all:
        print("\n(SQLcl housekeeping not listed; add --all to see every record)")


def compare(rows: list[dict], events_path: str) -> int:
    """Reconcile the harness log with the audit trail. Returns the number of
    agent statements the audit trail did not record."""
    events = [json.loads(line) for line in open(events_path, encoding="utf-8") if line.strip()]
    # The run's model: only statements tagged with it can be the agent's.
    model = run_model(events_path)
    # The agent's SQL, as the harness sent it to SQLcl (sql_run calls only).
    agent_sql = [e["arguments"]["sql"] for e in events
                 if e.get("event") == "tool_call" and e.get("tool") == "sql_run"
                 and isinstance(e.get("arguments"), dict) and "sql" in e["arguments"]]
    used = set()
    found, missing = [], []
    for sql in agent_sql:
        target = norm(sql)
        hit = None
        for i, r in enumerate(rows):
            # Each record matches one statement at most, and only this run's
            # tagged records can match (another client may run the same SQL).
            if i in used or not is_agent(r, model):
                continue
            text = norm(r.get("SQL_TEXT"))
            # Equal, or the audit text was cut by the export and is a prefix of the statement.
            cut = len(r.get("SQL_TEXT") or "") >= EXPORT_SQL_LIMIT
            if text and (text == target or (cut and target.startswith(text))):
                hit = i
                break
        if hit is None:
            missing.append(sql)
        else:
            used.add(hit)
            found.append((sql, rows[hit].get("RETURN_CODE")))

    print(f"=== The agent's statements (harness log): {len(agent_sql)}")
    print(f"=== Recorded by the database:            {len(found)}\n")
    # Self-diagnosis: tagged agent statements exist, yet nothing matched. Show
    # the raw text of both sides (repr shows hidden characters), so the
    # difference can be seen instead of guessed.
    tagged = [r for r in rows if is_agent(r, model)]
    if agent_sql and tagged and not found:
        print("    DIAGNOSIS: the audit trail has tagged agent statements, but none matched.")
        print(f"    harness, raw:      {agent_sql[0]!r}")
        print(f"    harness, normal:   {norm(agent_sql[0])!r}")
        print(f"    audit,   raw:      {tagged[0].get('SQL_TEXT')!r}")
        print(f"    audit,   normal:   {norm(tagged[0].get('SQL_TEXT'))!r}\n")
    for sql, rc in found:
        print(f"  {rc_label(rc):<10} {short(sql, 100)}")
    if missing:
        print(f"\n=== NOT in the audit trail: {len(missing)}")
        # The three causes seen in this lab, so the reader knows where to look.
        print("    (seen in this lab: a call the human rejected (--confirm) never ran;")
        print("     a statement naming an object the user cannot see at all fails before")
        print("     it becomes an auditable action; and a SELECT with FETCH FIRST is not")
        print("     recorded by an ONLY TOPLEVEL policy: see 06_test_fetch_first.sh)")
        for sql in missing:
            print(f"  {short(sql, 110)}")

    # Everything else the database recorded for the agent's user in the same window.
    others = [r for i, r in enumerate(rows) if i not in used]
    print(f"\n=== Other records in the same window: {len(others)}")
    print("    (logon/logoff and SQLcl's own housekeeping: the agent never mentions these)")
    for action, count in Counter(r.get("ACTION_NAME") for r in others).most_common():
        print(f"  {count:>4}  {action}")

    # What the agent said, for the third side of the comparison.
    end = next((e for e in events if e.get("event") == "run_end"), None)
    if end:
        answer = (end.get("final_answer") or "").strip().splitlines()
        print("\n=== What the agent said (final answer, last 30 lines)")
        for line in answer[-30:]:
            print(f"  | {line}")
    return len(missing)


def main() -> int:
    """Parse options and run the chosen mode."""
    # Piping the output into "head" or "less" should end quietly, not with a traceback.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    p = argparse.ArgumentParser(description="Show or reconcile the audit records of an agent run.")
    p.add_argument("--audit", required=True, help="Audit export: one JSON object per line")
    p.add_argument("--mode", choices=("show", "compare"), default="show")
    p.add_argument("--events", help="events.jsonl of the harness run (compare mode; in show mode, names the run's model)")
    p.add_argument("--all", action="store_true", help="show mode: list every record, including SQLcl housekeeping")
    args = p.parse_args()
    rows = read_audit(args.audit)
    if args.mode == "show":
        # With the run's log, only statements tagged with its model are the agent's.
        show(rows, args.all, run_model(args.events))
        return 0
    if not args.events:
        sys.exit("ERROR: --events is required in compare mode.")
    # Exit 1 if any agent statement is missing from the audit trail.
    return 1 if compare(rows, args.events) else 0


if __name__ == "__main__":
    sys.exit(main())
