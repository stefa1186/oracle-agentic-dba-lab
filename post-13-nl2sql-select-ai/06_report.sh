#!/usr/bin/env bash
# =============================================================================
# 03_report.sh
#
# Summarises a graded set of runs (05_grade.sh), the newest or the folder given:
# outcomes per model, metadata level and group; questions whose outcome
# changed between repetitions; and every WRONG answer next to its reference.
# Run as the lab user. Changes nothing.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01, 02 and 13 settings.
load_post13_config

# The run: the folder given, or the newest one.
run="${1:-$(ls -d "${OUT_DIR}"/set_* 2>/dev/null | tail -1)}"
[[ -f "${run}/results.csv" ]] || die "no results.csv in '${run}'. Run ./04_run_agent.sh and ./05_grade.sh first."
echo "Run: ${run}"
# The summary itself, in Python (standard library only); -I: isolated mode.
python3 -I - "${run}/results.csv" "${POST13_DIR}/questions.txt" <<'PY'
import csv, sys
from collections import Counter, defaultdict
rows = list(csv.DictReader(open(sys.argv[1])))
ref = {l.split("|", 3)[0]: l.split("|", 3) for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")}
outcomes = ["PASS", "WRONG", "ERROR", "SHAPE"]
# 1. Outcomes per model, metadata level and group.
print("\n== Outcomes per model, metadata and group")
print(f"{'model':42} {'metadata':9} {'group':7} " + " ".join(f"{o:>5}" for o in outcomes) + "  pass rate")
cells = defaultdict(Counter)
for r in rows:
    cells[(r["model"], r["metadata"], r["group"])][r["outcome"]] += 1
    cells[(r["model"], r["metadata"], "ALL")][r["outcome"]] += 1
for (m, meta, g), c in sorted(cells.items()):
    n = sum(c.values())
    print(f"{m:42.42} {meta:9} {g:7} " + " ".join(f"{c[o]:5}" for o in outcomes) + f"  {100 * c['PASS'] / n:5.0f}%")
# 2. Consistency: the same question, the same setup, different outcomes.
print("\n== Questions whose outcome changed between repetitions")
seen = defaultdict(list)
for r in rows:
    seen[(r["model"], r["metadata"], r["qid"])].append(r["outcome"])
changed = [(k, v) for k, v in seen.items() if len(set(v)) > 1]
for (m, meta, q), v in changed:
    print(f"  {m} | {meta} | {q}: {' '.join(v)}")
print(f"  {len(changed)} of {len(seen)} question/setup pairs" if seen else "  none")
# 3. Every distinct WRONG answer, next to the question and its reference.
print("\n== WRONG answers (each distinct SQL once)")
done = set()
for r in rows:
    if r["outcome"] == "WRONG" and (r["qid"], r["sql"]) not in done:
        done.add((r["qid"], r["sql"]))
        q = ref[r["qid"]]
        print(f"\n-- {r['qid']} ({r['model']}, {r['metadata']}): {q[2]}  [{r['detail']}]")
        print(f"   generated: {' '.join(r['sql'].split())}")
        print(f"   reference: {q[3]}")
PY
