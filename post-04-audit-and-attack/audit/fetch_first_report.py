#!/usr/bin/env python3
# =============================================================================
# fetch_first_report.py  (used by 06_test_fetch_first.sh, not run by hand)
#
# For each statement of a replay file: how many audit records each of two
# policies wrote for it, read from an audit export (one JSON object per line,
# lib.sh's fetch_audit_jsonl, with the POLICIES field). Statements are matched
# the way 04_compare.sh matches them (audit_report.norm: comments, case and
# whitespace removed).
#
# Prints one line per statement, then "MISSING=<n>": the statements the agent's
# policy did not record at all.
# =============================================================================

# argparse: command-line options.
import argparse
# pathlib: the folder of this script, to import audit_report next to it.
import pathlib
# sys: the import path.
import sys

# audit_report.py lives in the same folder.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
# norm: the statement normalisation of 04_compare.sh; read_audit: the export reader.
from audit_report import norm, read_audit


def statements(path: str) -> list[str]:
    """The statements of a replay file: each ends with ';' at the end of a
    line; lines starting with '--' and blank lines are skipped."""
    out, buf = [], []
    for line in open(path, encoding="utf-8"):
        # Comments and blank lines are not part of any statement.
        if line.lstrip().startswith("--") or not line.strip():
            continue
        # Collect the lines of the current statement.
        buf.append(line.rstrip("\n"))
        # A ';' at the end of a line ends it.
        if line.rstrip().endswith(";"):
            out.append(" ".join(buf).rstrip().rstrip(";").strip())
            buf = []
    return out


def cell(n: int) -> str:
    """'<n> record(s)', or NOT RECORDED for none."""
    return f"{n} record(s)" if n else "NOT RECORDED"


def main() -> int:
    """Parse the options, print the table and the MISSING line."""
    p = argparse.ArgumentParser(description="Audit records per statement and policy.")
    p.add_argument("--export", required=True, help="audit export (JSON lines)")
    p.add_argument("--tests", required=True, help="the replay file")
    p.add_argument("--agent-policy", required=True, help="the agent's policy name")
    p.add_argument("--test-policy", required=True, help="the temporary policy name")
    p.add_argument("--show-test", action="store_true", help="add a column for the temporary policy")
    args = p.parse_args()
    # Every record in the export window.
    rows = read_audit(args.export)
    # The header.
    header = f"{'STATEMENT':<62} {args.agent_policy:>22}"
    if args.show_test:
        header += f" {args.test_policy:>22}"
    print(header)
    # Statements the agent's policy did not record.
    missing = 0
    for s in statements(args.tests):
        # The records of this statement (any policy).
        hits = [r for r in rows if norm(r.get("SQL_TEXT")) == norm(s)]
        # Records written by each policy (UNIFIED_AUDIT_POLICIES lists every policy that matched).
        by_agent = sum(1 for r in hits if args.agent_policy in (r.get("POLICIES") or ""))
        by_test = sum(1 for r in hits if args.test_policy in (r.get("POLICIES") or ""))
        missing += by_agent == 0
        line = f"{s[:62]:<62} {cell(by_agent):>22}"
        if args.show_test:
            line += f" {cell(by_test):>22}"
        print(line)
    print(f"MISSING={missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
