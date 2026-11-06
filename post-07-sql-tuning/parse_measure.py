#!/usr/bin/env python3
# =============================================================================
# parse_measure.py
#
# Reads the raw output of one measurement (lib.sh: measure_query) and prints
# a one-line summary, or the fields one per line with --fields:
#   SQL_ID, BUFFERS and A_TIME of the last execution (the plan's Id 0 row),
#   PLAN (the operations, in order: "SORT AGGREGATE > TABLE ACCESS FULL ORDERS"),
#   RESULT (what the query returned, the last run).
# Plain Python, no extra packages. Changes nothing.
# =============================================================================

# argparse: options. re: the SQL_ID line. sys: exit codes.
import argparse
import re
import sys


def parse(path: str) -> dict:
    """The summary fields from one measurement file."""
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    out = {"SQL_ID": "", "BUFFERS": "", "A_TIME": "", "PLAN": "", "RESULT": ""}

    # The SQL_ID line written by the measurement. SQL*Plus pads the substituted
    # child number with spaces ("CHILD=         1"), so spaces are allowed.
    for line in lines:
        m = re.match(r"SQL_ID=(\S+) CHILD=\s*(\d+)", line.strip())
        if m:
            out["SQL_ID"] = m.group(1)

    # The result of the LAST run: the lines between the last pair of markers.
    begins = [i for i, l in enumerate(lines) if l.strip() == "#RESULT_BEGIN#"]
    ends = [i for i, l in enumerate(lines) if l.strip() == "#RESULT_END#"]
    if begins and ends and ends[-1] > begins[-1]:
        rows = [" ".join(l.split()) for l in lines[begins[-1] + 1:ends[-1]] if l.strip()]
        out["RESULT"] = " / ".join(rows)

    # The plan table: the header row names the columns; rows start with "|".
    header = next((l for l in lines if l.startswith("|") and "Operation" in l and "Buffers" in l), None)
    if header:
        cols = [c.strip() for c in header.strip().strip("|").split("|")]
        ops = []
        for l in lines:
            if not l.startswith("|") or l == header or set(l.strip()) <= set("|-"):
                continue
            cells = [c.strip() for c in l.strip().strip("|").split("|")]
            if len(cells) != len(cols):
                continue
            row = dict(zip(cols, cells))
            # The Id column may carry a "*" (a predicate on that step).
            ident = row.get("Id", "").lstrip("*").strip()
            if not ident.isdigit():
                continue
            # The operation and the object it works on.
            ops.append(" ".join(x for x in (row.get("Operation", ""), row.get("Name", "")) if x))
            # Id 0 holds the totals for the whole statement.
            if ident == "0":
                out["BUFFERS"] = row.get("Buffers", "")
                out["A_TIME"] = row.get("A-Time", "")
        # The statement line itself ("SELECT STATEMENT") says nothing: leave it out.
        out["PLAN"] = " > ".join(op for op in ops if not op.startswith("SELECT STATEMENT"))
    return out


def main() -> int:
    """Print the summary of one measurement file."""
    p = argparse.ArgumentParser(description="Summarise one query measurement.")
    p.add_argument("file")
    p.add_argument("--fields", action="store_true", help="One FIELD=value per line")
    args = p.parse_args()
    s = parse(args.file)
    if not s["BUFFERS"]:
        print(f"ERROR: no plan statistics in {args.file}", file=sys.stderr)
        return 2
    if args.fields:
        for k, v in s.items():
            print(f"{k}={v}")
    else:
        print(f"buffers {s['BUFFERS']:>8}  a-time {s['A_TIME']:>11}  result [{s['RESULT']}]  plan: {s['PLAN']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
