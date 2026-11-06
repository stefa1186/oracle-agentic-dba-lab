#!/usr/bin/env bash
# =============================================================================
# 02_collect_runs.sh
#
# One table of every agent run in the lab: post, model, provider, steps,
# tokens, how it ended, SQL statements, ORA- errors, approvals. Counted from
# the harness's own logs (events.jsonl), never from the agents' answers.
#
#   ./02_collect_runs.sh                         the runs under output/
#   ./02_collect_runs.sh <label>=<folder> ...    any output folders, labelled
#                                                (e.g. an archived set of runs)
#
# Writes runs.md (every column, Markdown) and runs.txt (the narrow table it
# prints) in this post's output folder.
# Oracle analogy: a report from DBA_HIST, not from the users' recollection.
#
# Run as the lab user. Reads files only.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Post 11's folder, and the repository root above it.
POST11_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${POST11_DIR}/.." && pwd)"
# Post 01's helpers: step, info, die, settings, the lab user.
# shellcheck source=../post-01-why-and-the-cage/lib.sh
source "${REPO_DIR}/post-01-why-and-the-cage/lib.sh"
load_config
require_lab_user

# This post's evidence folder.
OUT_DIR="${REPO_DIR}/output/post-11-verdict"
mkdir -p "${OUT_DIR}"
# Default: the lab's own output folder, labelled "runs".
if [[ $# -eq 0 ]]; then
    set -- "runs=${REPO_DIR}/output"
fi
# Every argument must be label=folder, and the folder must exist.
for arg in "$@"; do
    [[ "${arg}" == *=* ]] || die "expected <label>=<folder>, got: ${arg}"
    [[ -d "${arg#*=}" ]] || die "not a folder: ${arg#*=}"
done

# Every column, as Markdown, for the record.
python3 "${POST11_DIR}/collect_runs.py" --format md "$@" > "${OUT_DIR}/runs.md"
# The narrow version, on the terminal and in runs.txt.
python3 "${POST11_DIR}/collect_runs.py" --format text "$@" | tee "${OUT_DIR}/runs.txt"
step "Saved"
info "${OUT_DIR}/runs.md (every column) and ${OUT_DIR}/runs.txt (this table)"
