#!/usr/bin/env python3
# =============================================================================
# check_claims.py  (run by 05_check_claims.sh)
#
# Checks the agent's AWR diagnosis against the report it was given. Three
# mechanical checks, then a scorecard with SUGGESTED marks; the final marks
# are mine (edited in the scorecard):
#   ✅ right, and grounded in the report
#   ⚠️ the line is in the report, but the conclusion drawn from it is wrong
#   👻 made up: the quoted line or a number isn't in the report
#
#   1. GROUNDING: is each FINDING's quoted line really in the report? Compared
#      after collapsing whitespace (the model may re-space AWR's columns).
#      If not verbatim: is it STITCHED, i.e. made of several real report lines
#      glued together (observed: rows from different sections in one quote)?
#      If not: is there one report line with all the quote's numbers?
#   2. NUMBERS: every number in the whole answer that appears nowhere in the
#      report. Those that are a report number rounded (2,693 for 2,692.9,
#      83.8 for 83.80) are listed apart; the rest may be the agent's own
#      arithmetic or invented, so they are for review, not automatically wrong.
#   3. PLANTED PROBLEMS: which findings mention each of the two planted
#      problems (keyword match), and at which rank.
#
# Inputs: --report awr_report.txt, --events events.jsonl, --answer-key answer_key.txt
# Output: the scorecard (Markdown) on stdout.
# Plain Python, no extra packages. Changes nothing.
# =============================================================================

# argparse: options. json: the harness log. re: numbers and whitespace. sys: exit codes.
import argparse
import json
import re
import sys

# Keywords that show a finding is about each planted problem. Lower case.
PLANTED = {
    "ROW_LOCK": ("row lock", "enq: tx", "tx - row", "lock contention", "blocking session", "blocker"),
    "HARD_PARSE": ("hard parse", "parse count (hard)", "literal", "bind variable", "cursor_sharing",
                   "hard-parse", "parsing"),
}
# A number as AWR prints it: digits with optional thousands separators and
# decimals, possibly followed by a unit (4.98s, 5.55ms, 66.1%): the unit is
# not part of the match. Digits inside a word (an SQL_ID, V$SGA2) don't count.
NUMBER = re.compile(r"(?<![\w.])\d{1,3}(?:,\d{3})+(?:\.\d+)?(?![\d,])|(?<![\w.,])\d+(?:\.\d+)?(?![\d.,])")


def squash(text: str) -> str:
    """One line, single spaces, no surrounding quotes or backticks: for comparing lines."""
    return " ".join((text or "").strip().strip("`\"'").split())


def numbers_in(text: str) -> list[str]:
    """The numbers in a text, as written (with separators), ignoring single digits."""
    return [n for n in NUMBER.findall(text or "") if len(n.replace(",", "").replace(".", "")) >= 2]


def final_answer(events_path: str) -> str:
    """The agent's final answer, from the run_end event of the harness log."""
    with open(events_path, encoding="utf-8") as fh:
        events = [json.loads(line) for line in fh if line.strip()]
    ends = [e for e in events if e.get("event") == "run_end"]
    return (ends[-1].get("final_answer") or "") if ends else ""


def parse_findings(answer: str) -> list[dict]:
    """FINDING | problem | section | quoted line  ->  dicts, in the order given."""
    out = []
    for line in answer.splitlines():
        parts = [p.strip() for p in line.strip().strip("`").split("|")]
        if len(parts) >= 4 and parts[0].upper() == "FINDING":
            # The quote is everything after the third "|": AWR lines rarely contain "|", but may.
            out.append({"problem": parts[1], "section": parts[2], "quote": " | ".join(parts[3:])})
    return out


def stitched_from(quote: str, report_lines: list[str]) -> int:
    """How many distinct report lines the quote is made of, if (almost) all of
    it is covered by whole report lines; 0 if not. A report line counts when it
    appears inside the quote; at least 90% of the quote's characters must be
    covered, so a few joining spaces or separators don't matter."""
    q = squash(quote)
    if not q:
        return 0
    covered = [False] * len(q)
    used = set()
    # Longest lines first, so a long row isn't 'covered' by a short common one.
    for line in sorted(set(report_lines), key=len, reverse=True):
        # Very short lines ('---', a single word) would match anywhere: skip them.
        if len(line) < 12:
            continue
        start = q.find(line)
        while start != -1:
            # Count the line only if it covers characters not yet covered.
            if not all(covered[start:start + len(line)]):
                for i in range(start, start + len(line)):
                    covered[i] = True
                used.add(line)
            start = q.find(line, start + 1)
    non_space = [c for i, c in enumerate(covered) if q[i] != " "]
    share = sum(non_space) / max(1, len(non_space))
    return len(used) if len(used) >= 2 and share >= 0.9 else 0


def cell(text: str) -> str:
    """Make text safe inside a Markdown table cell."""
    return (text or "").replace("|", "\\|")


def main() -> int:
    """Run the three checks and print the scorecard."""
    p = argparse.ArgumentParser(description="Check an agent's AWR diagnosis against the report.")
    p.add_argument("--report", required=True)
    p.add_argument("--events", required=True)
    p.add_argument("--answer-key", required=True)
    args = p.parse_args()

    report = open(args.report, encoding="utf-8", errors="replace").read()
    # Report lines, whitespace-collapsed, for the grounding check.
    report_lines = [squash(l) for l in report.splitlines() if l.strip()]
    report_flat = " ".join(report_lines)
    # Every number string in the report, with and without thousands separators.
    report_numbers = set(numbers_in(report)) | {n.replace(",", "") for n in numbers_in(report)}
    key = [l.rstrip("\n") for l in open(args.answer_key, encoding="utf-8") if l.strip()]
    answer = final_answer(args.events)
    findings = parse_findings(answer)

    # No findings: say why, rather than score nothing.
    if not findings:
        print("ERROR: no 'FINDING | ...' lines in the agent's final answer. Last lines of the answer:", file=sys.stderr)
        for line in answer.strip().splitlines()[-10:]:
            print(f"       | {line}", file=sys.stderr)
        return 2

    # ---- 1. Grounding -------------------------------------------------------
    for f in findings:
        q = squash(f["quote"])
        if q and q in report_flat:
            # The quote is in the report as written (whitespace aside).
            f["grounding"] = "verbatim"
        elif (n := stitched_from(f["quote"], report_lines)):
            # Real report lines, glued together from different places.
            f["grounding"] = f"stitched from {n} report lines"
        else:
            # Not verbatim: is there one report line holding all of the quote's numbers?
            nums = numbers_in(f["quote"])
            hits = [l for l in report_lines if nums and all(n in l for n in nums)]
            f["grounding"] = "numbers on one line" if hits else "NOT IN REPORT"
            f["near"] = hits[0] if hits else ""

    # ---- 2. Numbers in the answer that the report doesn't contain ------------
    unknown = sorted({n for n in numbers_in(answer)
                      if n not in report_numbers and n.replace(",", "") not in report_numbers},
                     key=lambda n: float(n.replace(",", "")))
    # Split them: a report number ROUNDED to the precision the agent wrote, or not.
    report_values = sorted({float(n.replace(",", "")) for n in report_numbers})
    rounded, unexplained = {}, []
    for n in unknown:
        value = float(n.replace(",", ""))
        # Decimals the agent wrote: 0 for "2,693", 1 for "83.8".
        decimals = len(n.split(".")[1]) if "." in n else 0
        # Rounded OR truncated: within one unit of the last digit the agent wrote
        # (12,533 for 12,533.5; 2,693 for 2,692.9; 83.8 for 83.80).
        match = next((r for r in report_values if abs(r - value) < 10 ** -decimals), None)
        if match is not None:
            rounded[n] = match
        else:
            unexplained.append(n)

    # ---- 3. The planted problems ---------------------------------------------
    planted_rank = {}
    for name, words in PLANTED.items():
        ranks = [i + 1 for i, f in enumerate(findings)
                 if any(w in (f["problem"] + " " + f["quote"]).lower() for w in words)]
        planted_rank[name] = ranks

    # ---- The scorecard -------------------------------------------------------
    print("# AWR diagnosis scorecard\n")
    print("## The planted problems\n")
    for name, ranks in planted_rank.items():
        where = ", ".join(f"#{r}" for r in ranks) if ranks else "not mentioned"
        print(f"- **{name}**: {'found' if ranks else 'MISSED'} (findings {where})")
    print("\nWhat AWR measured (answer key):\n")
    print("```")
    for line in key:
        print(line)
    print("```\n")

    print("## The agent's findings, in its order\n")
    print("Suggested mark: 👻 if the quoted line isn't in the report; otherwise ✅ or ⚠️,")
    print("which only reading the report can decide. 'stitched' = real lines from")
    print("different places in the report, joined into one quote: not invented.\n")
    print("| # | Problem | Section | Quote found in report | Mark |")
    print("|---|---|---|---|---|")
    for i, f in enumerate(findings, 1):
        mark = "👻 ?" if f["grounding"] == "NOT IN REPORT" else "✅ / ⚠️ ?"
        print(f"| {i} | {cell(f['problem'])} | {cell(f['section'])} | {f['grounding']} | {mark} |")

    print("\n### The quotes\n")
    for i, f in enumerate(findings, 1):
        print(f"{i}. `{f['quote']}`  ")
        print(f"   → {f['grounding']}" + (f" (closest line: `{f['near']}`)" if f.get("near") else ""))

    print("\n## Numbers in the answer that appear nowhere in the report\n")
    if unexplained:
        print("Each is either the agent's own arithmetic (check it) or invented (👻):\n")
        print(", ".join(unexplained))
    else:
        print("None: every number in the answer appears in the report, as written or rounded.")
    if rounded:
        print("\nRounded or truncated from a report number (not invented):\n")
        print(", ".join(f"{n} ≈ {r:g}" for n, r in rounded.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
