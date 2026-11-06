#!/usr/bin/env python3
# =============================================================================
# score.py  (run by 05_score.sh)
#
# Compares the agent's findings with my checklist's, and writes a scorecard
# with a SUGGESTED mark for every line. The suggestion is mechanical; the
# final mark is mine to give, by editing the scorecard:
#   ✅ found it, explained correctly    ⚠️ found it, explanation wrong or shallow
#   ❌ missed it                         👻 reported a problem that doesn't exist
#   ➖ true, but not a problem (noise a DBA would filter out)
#
# Inputs:
#   --checklist  checklist.txt (lines "FINDING | cat | object | what")
#   --answer-key answer_key.txt (lines "SEEDED | cat | object | what")
#   --events     the run's events.jsonl (the agent's final answer is in it)
# Output: the scorecard (Markdown) on stdout.
#
# Matching rule, deliberately simple and predictable: an agent finding matches
# a checklist finding when the CATEGORY is the same and the checklist's object
# name appears in the agent's line (as a whole word, case-insensitive), or the
# agent's object is the last part of it (HC_ORDERS for HC_SEED.HC_ORDERS).
# Anything the rule can't pair is listed as unmatched, for me to pair by hand.
#
# Plain Python, no extra packages. Changes nothing.
# =============================================================================

# argparse: options. json: the harness log. re: whole-word matching. sys: exit codes.
import argparse
import json
import re
import sys

# The categories the prompt and the checklist both use.
CATEGORIES = ("STORAGE", "OBJECTS", "STATS", "SECURITY", "BACKUP", "MEMORY")


def parse_lines(lines: list[str], kind: str) -> list[dict]:
    """Parse 'KIND | category | object | what' lines into dicts; other lines are skipped."""
    out = []
    for line in lines:
        # Split on "|" and trim each field.
        parts = [p.strip() for p in line.strip().strip("`").split("|")]
        # Only lines of the requested kind, with all four fields.
        if len(parts) >= 4 and parts[0].upper() == kind:
            # Everything after the third "|" is the description, even if it contains "|".
            out.append({"cat": parts[1].upper(), "obj": parts[2], "what": " | ".join(parts[3:]), "line": line.strip()})
    return out


def final_answer(events_path: str) -> str:
    """The agent's final answer, from the run_end event of the harness log."""
    with open(events_path, encoding="utf-8") as fh:
        # One JSON object per line; skip blank lines.
        events = [json.loads(line) for line in fh if line.strip()]
    # The last run_end event holds the final answer.
    ends = [e for e in events if e.get("event") == "run_end"]
    return (ends[-1].get("final_answer") or "") if ends else ""


def matches(check: dict, agent: dict) -> bool:
    """True when the agent finding is about the same thing as the checklist finding."""
    # Different category: never the same finding.
    if check["cat"] != agent["cat"]:
        return False
    # The checklist object as a whole word anywhere in the agent's line.
    obj = check["obj"].upper()
    text = agent["line"].upper()
    if obj not in ("", "-") and re.search(r"(?<![A-Z0-9_$#])" + re.escape(obj) + r"(?![A-Z0-9_$#])", text):
        return True
    # The agent named the object without its owner: HC_ORDERS for HC_SEED.HC_ORDERS.
    short = agent["obj"].upper().strip('"')
    return bool(short) and short != "-" and obj.endswith("." + short)


def cell(text: str) -> str:
    """Make text safe inside a Markdown table cell."""
    return text.replace("|", "\\|")


def main() -> int:
    """Parse options, pair the findings, print the scorecard."""
    p = argparse.ArgumentParser(description="Score the agent's health check against the DBA checklist.")
    p.add_argument("--checklist", required=True)
    p.add_argument("--answer-key", required=True)
    p.add_argument("--events", required=True)
    args = p.parse_args()

    # The three inputs.
    checks = parse_lines(open(args.checklist, encoding="utf-8").read().splitlines(), "FINDING")
    seeded = parse_lines(open(args.answer_key, encoding="utf-8").read().splitlines(), "SEEDED")
    answer = final_answer(args.events)
    agent = parse_lines(answer.splitlines(), "FINDING")

    # No findings in the agent's answer: say why, rather than score everything as missed.
    if not agent:
        print("ERROR: no 'FINDING | ...' lines in the agent's final answer.", file=sys.stderr)
        print("       (stopped at MAX_STEPS? different format?) Last lines of the answer:", file=sys.stderr)
        for line in answer.strip().splitlines()[-10:]:
            print(f"       | {line}", file=sys.stderr)
        return 2

    # Pair each checklist finding with the agent findings about the same thing.
    # An agent finding can pair with one checklist finding only (the first that matches).
    used = set()
    pairs = []
    for c in checks:
        hits = [i for i, a in enumerate(agent) if i not in used and matches(c, a)]
        used.update(hits)
        pairs.append((c, [agent[i] for i in hits]))
    # Agent findings that matched nothing on the checklist.
    extras = [a for i, a in enumerate(agent) if i not in used]
    # Seeded problems and whether the agent found each.
    seeded_keys = {(s["cat"], s["obj"].upper()) for s in seeded}

    # ---- The scorecard -----------------------------------------------------
    found = sum(1 for _, hits in pairs if hits)
    print("# Health check scorecard\n")
    print(f"- Checklist findings: **{len(checks)}** (of which seeded: {len(seeded)})")
    print(f"- Agent findings: **{len(agent)}**")
    print(f"- Paired automatically: **{found} of {len(checks)}** checklist findings")
    print(f"- Agent findings not on the checklist: **{len(extras)}**\n")
    print("Suggested marks are mechanical: confirm or correct each one, and pair")
    print("anything the rule missed by hand.\n")

    # Per category: the checklist findings, what the agent said, the suggested mark.
    print("## Checklist findings\n")
    print("| Category | Object | Seeded | Checklist says | Agent says | Mark |")
    print("|---|---|---|---|---|---|")
    for c, hits in sorted(pairs, key=lambda x: (CATEGORIES.index(x[0]["cat"]) if x[0]["cat"] in CATEGORIES else 99, x[0]["obj"])):
        is_seeded = "yes" if (c["cat"], c["obj"].upper()) in seeded_keys else ""
        said = "<br>".join(cell(h["what"]) for h in hits) or "—"
        mark = "✅ ?" if hits else "❌ ?"
        print(f"| {c['cat']} | {cell(c['obj'])} | {is_seeded} | {cell(c['what'])} | {said} | {mark} |")

    # Agent findings with no counterpart: invented, or real and missing from my checklist.
    print("\n## Agent findings not on the checklist\n")
    if extras:
        print("Each is ✅ (real, and my checklist doesn't cover it), ➖ (true, but not")
        print("a problem) or 👻 (wrong). Check each against the database (06_judge_extras.sh).\n")
        print("| Category | Object | Agent says | Mark |")
        print("|---|---|---|---|")
        for a in extras:
            print(f"| {cell(a['cat'])} | {cell(a['obj'])} | {cell(a['what'])} | ? |")
    else:
        print("None.")

    # The headline numbers per category, for the article.
    print("\n## By category (paired automatically)\n")
    for cat in CATEGORIES:
        in_cat = [(c, h) for c, h in pairs if c["cat"] == cat]
        if in_cat:
            print(f"- {cat}: {sum(1 for _, h in in_cat if h)} of {len(in_cat)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
