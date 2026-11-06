#!/usr/bin/env python3
# =============================================================================
# fix_lines.py  (run by 06_try_fix.sh)
#
# Turns suggested changes into a checked list 06_try_fix.sh can test, one per
# line, tab-separated:
#   REWRITE  <sql>                          a single SELECT (or WITH ... SELECT)
#   DDL      <statement>  <OWNER.INDEX>     a CREATE INDEX on the lab table only
#   PROFILE  <task name>                    a SQL profile from SQL Tuning Advisor
#   REJECTED <reason>     <original line>   anything else: shown, never run
#
# Sources: --events <events.jsonl> (the agent's final answer: REWRITE | and
# DDL | lines) or --fixes <advisor_fixes.txt> (written by 04_tuning_advisor.sh).
#
# Why so strict: these statements are run automatically. Only what can be
# undone exactly (DROP INDEX, DROP SQL PROFILE) or what only reads (SELECT)
# is accepted. Plain Python, no extra packages. Changes nothing itself.
# =============================================================================

# argparse: options. json: the harness log. re: statement checks. sys: exit codes.
import argparse
import json
import re
import sys

# Words that never belong in a rewrite of a SELECT (as whole words).
FORBIDDEN = re.compile(r"\b(insert|update|delete|merge|drop|alter|grant|revoke|truncate|create|begin|declare|execute|exec|call|commit|rollback)\b", re.I)
# One Oracle name, plain or quoted (index names from the advisor contain $).
NAME = r'(?:"[^"]+"|[A-Za-z][\w$#]*)'
# CREATE [UNIQUE|BITMAP] INDEX [owner.]name ON [owner.]table ( columns ) [simple options]
CREATE_INDEX = re.compile(
    rf"^create\s+(?:unique\s+|bitmap\s+)?index\s+(?:({NAME})\.)?({NAME})\s+on\s+(?:({NAME})\.)?({NAME})\s*\((.+)\)\s*([\w\s]*)$",
    re.I | re.S)


def plain(name: str | None) -> str:
    """An Oracle name as the dictionary stores it: quoted as is, unquoted in upper case."""
    if not name:
        return ""
    return name[1:-1] if name.startswith('"') else name.upper()


def check_rewrite(sql: str) -> tuple[str, str]:
    """('REWRITE', sql) if it's one SELECT and nothing else, else ('REJECTED', reason)."""
    s = sql.strip().strip("`").strip().rstrip(";").strip()
    if not re.match(r"^(select|with)\b", s, re.I):
        return "REJECTED", "a rewrite must be a SELECT (or WITH ... SELECT)"
    if ";" in s:
        return "REJECTED", "a rewrite must be a single statement"
    if FORBIDDEN.search(s):
        return "REJECTED", f"a rewrite must only read (found '{FORBIDDEN.search(s).group(0)}')"
    return "REWRITE", s


def check_ddl(stmt: str, schema: str) -> tuple[str, str, str]:
    """('DDL', statement, OWNER.INDEX) for a CREATE INDEX on <schema>.ORDERS, else REJECTED."""
    s = stmt.strip().strip("`").strip().rstrip(";").strip()
    m = CREATE_INDEX.match(s)
    if not m:
        return "REJECTED", "only CREATE INDEX statements are tested", s
    idx_owner, idx_name, tab_owner, tab_name, _cols, options = m.groups()
    # Only the lab table, in the lab schema (or unqualified: run with CURRENT_SCHEMA = the lab schema).
    if plain(tab_name) != "ORDERS" or (tab_owner and plain(tab_owner) != schema):
        return "REJECTED", f"only indexes on {schema}.ORDERS are tested", s
    if idx_owner and plain(idx_owner) != schema:
        return "REJECTED", f"the index must belong to {schema}", s
    # Options after the column list: plain words only (ONLINE, COMPRESS 1, INVISIBLE, ...), nothing forbidden.
    if options and FORBIDDEN.search(options):
        return "REJECTED", "unexpected words after the column list", s
    return "DDL", s, f"{schema}.{plain(idx_name)}"


def lines_from_events(path: str) -> list[str]:
    """The REWRITE | and DDL | lines of the agent's final answer."""
    events = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    ends = [e for e in events if e.get("event") == "run_end"]
    answer = (ends[-1].get("final_answer") or "") if ends else ""
    return [l.strip().strip("`") for l in answer.splitlines() if re.match(r"^\s*`?(REWRITE|DDL)\s*\|", l, re.I)]


def main() -> int:
    """Read the suggested changes, check each, print the checked list."""
    p = argparse.ArgumentParser(description="Check suggested query changes before they are tested.")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--events", help="events.jsonl of an agent run")
    src.add_argument("--fixes", help="advisor_fixes.txt from 04_tuning_advisor.sh")
    p.add_argument("--schema", required=True, help="The lab schema, e.g. TUNE_LAB")
    args = p.parse_args()

    raw = lines_from_events(args.events) if args.events else \
        [l.strip() for l in open(args.fixes, encoding="utf-8") if l.strip()]
    rewrites = 0
    for line in raw:
        kind, _, rest = line.partition("|")
        kind, rest = kind.strip().upper(), rest.strip()
        if kind == "REWRITE":
            rewrites += 1
            if rewrites > 1:
                print(f"REJECTED\tonly one rewrite is tested\t{line}")
                continue
            result = check_rewrite(rest)
            print("\t".join(result) if result[0] == "REWRITE" else f"REJECTED\t{result[1]}\t{line}")
        elif kind == "DDL":
            result = check_ddl(rest, args.schema)
            print("\t".join(result) if result[0] == "DDL" else f"REJECTED\t{result[1]}\t{line}")
        elif kind == "PROFILE" and args.fixes:
            # Only the advisor's own task: the name comes from 04_tuning_advisor.sh.
            print(f"PROFILE\t{rest}" if re.match(r"^[A-Z0-9_]+$", rest) else f"REJECTED\tbad task name\t{line}")
        else:
            print(f"REJECTED\tunknown kind of change\t{line}")
    if not raw:
        print("REJECTED\tno REWRITE or DDL lines found\t-")
    return 0


if __name__ == "__main__":
    sys.exit(main())
