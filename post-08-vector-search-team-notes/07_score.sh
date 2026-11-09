#!/usr/bin/env bash
# =============================================================================
# 07_score.sh
#
# Scores every post 08 agent run (score_answers.py): with and without the
# team notes, how many of OUR team notes' markers the answer contains, and which
# team-specific details it named that no team note has. Writes scorecard.md and
# prints it; then, with --answers, every answer in full.
#
#   ./07_score.sh               the scorecard
#   ./07_score.sh --answers     the scorecard, then each run's full answer
#
# Run as the lab user. Reads files only: no database access needed.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-08 settings.
load_post08_config
# Must be the lab user.
require_lab_user

# Every run of this post: <timestamp>/<model>/run-N.
mapfile -t runs < <(ls -1d "${POST08_OUT}"/*/*/run-* 2>/dev/null | sort)
(( ${#runs[@]} > 0 )) || die "no agent runs under ${POST08_OUT}: run ./06_run_agent.sh first."

step "Retrieval (from ./04_search.sh)"
[[ -f "${POST08_OUT}/retrieval.txt" ]] && sed 's/^/    /' "${POST08_OUT}/retrieval.txt"

step "Answers (${#runs[@]} runs)"
python3 "${POST08_DIR}/score_answers.py" --runs "${runs[@]}" \
    --questions "${QUESTIONS}" --team-notes "${TEAM_NOTES_DIR}" > "${POST08_OUT}/scorecard.md"
cat "${POST08_OUT}/scorecard.md"

if [[ "${1:-}" == "--answers" ]]; then
    for run in "${runs[@]}"; do
        step "${run}"
        # Which file it read, then its answer.
        python3 - "${run}/events.jsonl" <<'PY'
import json, pathlib, sys
events = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
start = next(e for e in events if e.get("event") == "run_start")
end = next(e for e in reversed(events) if e.get("event") == "run_end")
print("    read: " + ", ".join(pathlib.Path(a["file"]).name for a in start.get("attached") or []))
print("\n".join("    | " + l for l in (end.get("final_answer") or "").splitlines()))
PY
    done
fi

step "Done"
info "Saved: ${POST08_OUT}/scorecard.md"
