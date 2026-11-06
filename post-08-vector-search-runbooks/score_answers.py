#!/usr/bin/env python3
# =============================================================================
# score_answers.py  (run by 07_score.sh)
#
# Scores every post 08 agent run, mechanically:
#   - which question it answered, and WITH or WITHOUT the runbooks (from the
#     file the harness attached, logged in run_start)
#   - MARKERS: how many of the question's markers (questions.txt, MARK lines:
#     phrases only OUR runbooks contain) appear in the answer
#   - INVENTED: team-specific details in the answer (script names, paths,
#     #channels, ticket numbers) that appear in NO runbook: the prompt said
#     never to invent them
# Then a table, without vs with, per question. Whether the steps are right is
# still a DBA's judgment: this only counts what can be counted.
#
# Inputs: --runs <run folders...>, --questions questions.txt, --runbooks <dir>
#         --by-model (optional): one more column, the model, for runs of
#         several models side by side (post 12). Without it, the output is
#         exactly what post 08 printed.
# Output: Markdown on stdout. Plain Python, no extra packages. Changes nothing.
# =============================================================================

# argparse: options. json: harness logs. pathlib: files. re: patterns. sys: exit codes.
import argparse
import json
import pathlib
import re
import sys

# Team-specific details: a script or SQL file name, an absolute path, a
# #channel, or a ticket reference like SEC-1234 / CHG-42.
SPECIFIC = re.compile(r"(?<![\w/])(?:/[\w.-]+){2,}|\b[\w-]+\.(?:sh|sql|py)\b|(?<!\w)#[a-z][\w-]+|\b[A-Z]{2,5}-\d+\b")


def load_markers(path: str) -> dict[str, list[str]]:
    """MARK lines from questions.txt: question id -> marker phrases."""
    out: dict[str, list[str]] = {}
    for line in open(path, encoding="utf-8"):
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 3 and parts[0] == "MARK":
            out.setdefault(parts[1], []).append(parts[2])
    return out


def run_info(run_dir: pathlib.Path) -> dict | None:
    """Question id, with/without, and the final answer of one run; None if not a post 08 run."""
    events = [json.loads(l) for l in (run_dir / "events.jsonl").open(encoding="utf-8") if l.strip()]
    start = next((e for e in events if e.get("event") == "run_start"), {})
    end = next((e for e in reversed(events) if e.get("event") == "run_end"), {})
    attached = [pathlib.Path(a["file"]).name for a in start.get("attached") or []]
    m = next((re.match(r"(question|context)_(.+)\.txt$", n) for n in attached if re.match(r"(question|context)_", n)), None)
    if not m:
        return None
    return {"id": m.group(2), "with": m.group(1) == "context",
            "answer": end.get("final_answer") or "", "run": str(run_dir),
            "model": start.get("model") or "?"}


def main() -> int:
    """Score every run and print the table."""
    p = argparse.ArgumentParser(description="Score post 08 agent runs.")
    p.add_argument("--runs", nargs="+", required=True)
    p.add_argument("--questions", required=True)
    p.add_argument("--runbooks", required=True)
    # Optional model column (post 12 compares several models on the same questions).
    p.add_argument("--by-model", action="store_true")
    args = p.parse_args()

    markers = load_markers(args.questions)
    # Everything our runbooks contain, to tell real team details from invented ones.
    runbook_text = "\n".join(f.read_text(encoding="utf-8") for f in sorted(pathlib.Path(args.runbooks).glob("*.md")))

    rows = []
    for r in args.runs:
        info = run_info(pathlib.Path(r))
        if not info:
            continue
        answer = info["answer"]
        wanted = markers.get(info["id"], [])
        found = [m for m in wanted if m.lower() in answer.lower()]
        # Team-specific details the answer uses that no runbook contains.
        invented = sorted({s for s in SPECIFIC.findall(answer) if s not in runbook_text})
        rows.append({**info, "found": found, "wanted": wanted, "invented": invented})

    if not rows:
        print("ERROR: no post 08 runs among the folders given.", file=sys.stderr)
        return 2

    # Sort order: by question, without before with, then (with --by-model) by
    # model, then by run folder (time order).
    order = (lambda r: (r["id"], r["with"], r["model"], r["run"])) if args.by_model \
        else (lambda r: (r["id"], r["with"], r["run"]))
    print("# Runbook answers scorecard\n")
    if args.by_model:
        print("| Question | Runbooks | Model | Our markers in the answer | Team details found in no runbook |")
        print("|---|---|---|---|---|")
    else:
        print("| Question | Runbooks | Our markers in the answer | Team details found in no runbook |")
        print("|---|---|---|---|")
    for r in sorted(rows, key=order):
        marks = f"{len(r['found'])} of {len(r['wanted'])}" + (f": {', '.join(r['found'])}" if r["found"] else "")
        inv = ", ".join(f"`{s}`" for s in r["invented"]) or "none"
        model = f" {r['model']} |" if args.by_model else ""
        print(f"| {r['id']} | {'WITH' if r['with'] else 'without'} |{model} {marks} | {inv} |")

    print("\nMarkers are phrases only our runbooks contain (questions.txt). A detail")
    print("\"found in no runbook\" is a script, path, #channel or ticket the agent named")
    print("that our runbooks don't have: invented, or general knowledge (check each).\n")
    print("## The runs\n")
    for r in sorted(rows, key=order):
        model = f", {r['model']}" if args.by_model else ""
        print(f"- {r['id']}, {'WITH' if r['with'] else 'without'} runbooks{model}: `{r['run']}`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
