#!/usr/bin/env bash
# =============================================================================
# run_matrix.sh
#
# Runs one test-case prompt against every model listed in models.txt, one or
# more times each, so results can be compared model by model. Models can be
# hosted (OpenRouter) or local (Ollama, vLLM, llama.cpp server) in the same
# matrix.
#
# Oracle analogy: like running the same SQL under several optimizer settings
# and comparing the plans. Only one variable changes: the model.
#
# Usage:
#   ./run_matrix.sh [-r REPEATS] [-m MODELS_FILE] [-p PROVIDER] [-o OUTPUT_NAME] PROMPT_FILE [-- extra run_agent.py options]
#
# Examples:
#   ./run_matrix.sh ../post-05-health-check/04_prompt.md
#   ./run_matrix.sh -r 3 ../post-07-sql-tuning/04_prompt.md
#   ./run_matrix.sh -p local ../post-05-health-check/04_prompt.md     (local models only)
#   ./run_matrix.sh ../post-10-alert-log-rca/03_prompt.md -- --confirm
#   ./run_matrix.sh -o post-12-offline-local-models ../post-02-plugging-in-mcp/05_prompt.md
#       (an earlier post's prompt, with the runs filed under a later post)
#
# Output (never overwritten; each matrix run gets a new timestamp):
#   output/<post-folder>/<UTC timestamp>/<provider>_<model>/run-<n>/{events.jsonl,transcript.md}
#   output/<post-folder>/<UTC timestamp>/summary.tsv   (one line per run)
# <post-folder> is the prompt file's folder, or OUTPUT_NAME if -o is given.
# =============================================================================

# Fail fast on errors, unset variables and pipeline failures.
set -euo pipefail

# Absolute path of the harness folder.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Python interpreter of the harness virtual environment.
PYTHON="${HARNESS_DIR}/.venv/bin/python"
# Default: one run per model.
REPEATS=1
# Default model list.
MODELS_FILE="${HARNESS_DIR}/models.txt"
# Default: run every provider listed in the models file.
ONLY_PROVIDER=""
# Default: file the runs under the prompt file's folder name.
OUTPUT_NAME=""
# Usage line, reused in every error message.
USAGE="Usage: $0 [-r REPEATS] [-m MODELS_FILE] [-p openrouter|local] [-o OUTPUT_NAME] PROMPT_FILE [-- extra options]"

# Parse the short options -r, -m, -p and -o.
while getopts ":r:m:p:o:" opt; do
    case "${opt}" in
        # Number of runs per model (used for consistency tests, e.g. post 07).
        r) REPEATS="${OPTARG}" ;;
        # Alternative models file.
        m) MODELS_FILE="${OPTARG}" ;;
        # Run only the models of one provider (e.g. local, when offline).
        p) ONLY_PROVIDER="${OPTARG}" ;;
        # Output folder name under output/, instead of the prompt's folder name.
        o) OUTPUT_NAME="${OPTARG}" ;;
        # Anything else is a usage error.
        *) echo "${USAGE}" >&2; exit 1 ;;
    esac
done
# Drop the parsed options, leaving the prompt file and any extra options.
shift $((OPTIND - 1))

# The prompt file is mandatory.
if [[ $# -lt 1 ]]; then
    echo "${USAGE}" >&2
    exit 1
fi
# Absolute path to the prompt file, so it still resolves after directory changes.
PROMPT_FILE="$(readlink -f "$1")"
# Remove the prompt file from the argument list.
shift
# Skip the optional "--" separator; everything after it goes to run_agent.py unchanged.
if [[ "${1:-}" == "--" ]]; then shift; fi
# The remaining arguments are passed through to every run.
EXTRA_ARGS=("$@")

# Check the inputs before starting a long matrix.
[[ -x "${PYTHON}" ]]      || { echo "ERROR: run setup_harness.sh first." >&2; exit 1; }
[[ -f "${PROMPT_FILE}" ]] || { echo "ERROR: prompt file not found: ${PROMPT_FILE}" >&2; exit 1; }
[[ -f "${MODELS_FILE}" ]] || { echo "ERROR: models file not found: ${MODELS_FILE}" >&2; exit 1; }
# REPEATS must be a positive integer.
[[ "${REPEATS}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: -r must be a positive integer." >&2; exit 1; }

# -o, if given: a relative folder name (letters, digits, . _ - and /), never "..".
[[ -z "${OUTPUT_NAME}" || ( "${OUTPUT_NAME}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/${OUTPUT_NAME}/" != */../* ) ]] \
    || { echo "ERROR: -o must be a relative folder name (letters, digits, . _ - /)." >&2; exit 1; }
# -p, if given, must name a known provider.
[[ -z "${ONLY_PROVIDER}" || "${ONLY_PROVIDER}" =~ ^(openrouter|local)$ ]] || { echo "ERROR: -p must be openrouter or local." >&2; exit 1; }

# Read models.txt into two parallel arrays: provider and model ID.
# Each line is "<provider> <model-id>"; a line with only a model ID means openrouter.
PROVIDERS=()
MODELS=()
# Line number, for clear error messages.
lineno=0
# Read the file line by line, keeping whitespace handling under our control.
while IFS= read -r line || [[ -n "${line}" ]]; do
    # Count the line.
    lineno=$((lineno + 1))
    # Drop comments (everything after #).
    line="${line%%#*}"
    # Split the remaining text into words; extra spaces and tabs don't matter.
    read -r -a fields <<< "${line}"
    # Skip blank lines.
    [[ ${#fields[@]} -eq 0 ]] && continue
    # One word: an OpenRouter model ID (backward-compatible format).
    if [[ ${#fields[@]} -eq 1 ]]; then
        prov="openrouter"; mdl="${fields[0]}"
    # Two words: provider then model ID.
    elif [[ ${#fields[@]} -eq 2 ]]; then
        prov="${fields[0]}"; mdl="${fields[1]}"
    # Anything else is a formatting error worth stopping for.
    else
        echo "ERROR: ${MODELS_FILE} line ${lineno}: expected '<provider> <model-id>'." >&2; exit 1
    fi
    # Only known providers are accepted.
    [[ "${prov}" =~ ^(openrouter|local)$ ]] || { echo "ERROR: ${MODELS_FILE} line ${lineno}: unknown provider '${prov}'." >&2; exit 1; }
    # Apply the -p filter, if any.
    [[ -n "${ONLY_PROVIDER}" && "${prov}" != "${ONLY_PROVIDER}" ]] && continue
    # Keep the entry.
    PROVIDERS+=("${prov}")
    MODELS+=("${mdl}")
done < "${MODELS_FILE}"
# An empty list would do nothing silently; stop instead.
[[ ${#MODELS[@]} -gt 0 ]] || { echo "ERROR: no models to run in ${MODELS_FILE}${ONLY_PROVIDER:+ for provider ${ONLY_PROVIDER}}. See ./run_agent.py --list-models" >&2; exit 1; }

# Name of the post folder that owns the prompt, e.g. post-05-health-check.
# Runs are filed under the prompt's folder name, unless -o names another.
POST_NAME="${OUTPUT_NAME:-$(basename "$(dirname "${PROMPT_FILE}")")}"
# One timestamp for the whole matrix, so all its runs sit together.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Root folder of this matrix run, as a clean absolute path (readlink -m resolves
# the ".." even though the folder doesn't exist yet).
MATRIX_DIR="$(readlink -m "${HARNESS_DIR}/../output/${POST_NAME}/${STAMP}")"
# Create the parent folder for this post's results.
mkdir -p "$(dirname "${MATRIX_DIR}")"
# Create the run folder itself. mkdir without -p fails if it already exists
# (two matrices started in the same second), so add a numeric suffix until it
# succeeds. Earlier results are never overwritten.
suffix=1
base="${MATRIX_DIR}"
until mkdir "${MATRIX_DIR}" 2>/dev/null; do
    suffix=$((suffix + 1))
    MATRIX_DIR="${base}-${suffix}"
done
# Summary file header: one row per run, tab-separated for easy import into a spreadsheet.
printf 'provider\tmodel\trun\texit_code\tfolder\n' > "${MATRIX_DIR}/summary.tsv"

# Announce the plan.
echo "Matrix: ${#MODELS[@]} model(s) x ${REPEATS} run(s) for ${POST_NAME}"

# Loop over every model, by index so provider and model stay paired.
for i in "${!MODELS[@]}"; do
    # Provider and model ID of this entry.
    prov="${PROVIDERS[$i]}"
    model="${MODELS[$i]}"
    # Folder-safe name: provider plus model ID (same character rule as run_agent.py).
    safe="${prov}_$(echo "${model}" | sed 's/[^A-Za-z0-9.-]\+/_/g')"
    # Repeat the run REPEATS times.
    for n in $(seq 1 "${REPEATS}"); do
        # Folder for this single run.
        run_dir="${MATRIX_DIR}/${safe}/run-${n}"
        # Show progress.
        echo "--- ${prov}: ${model} (run ${n}/${REPEATS})"
        # Run the agent; "|| rc=$?" records a failure without stopping the whole matrix,
        # so one provider outage doesn't cost you the other models' results.
        rc=0
        "${PYTHON}" "${HARNESS_DIR}/run_agent.py" \
            --provider "${prov}" \
            --model "${model}" \
            --prompt-file "${PROMPT_FILE}" \
            --out-dir "${run_dir}" \
            "${EXTRA_ARGS[@]}" || rc=$?
        # Append the outcome to the summary.
        printf '%s\t%s\t%s\t%s\t%s\n' "${prov}" "${model}" "${n}" "${rc}" "${run_dir}" >> "${MATRIX_DIR}/summary.tsv"
    done
done

# Point to the results.
echo "Matrix complete: ${MATRIX_DIR}/summary.tsv"
# Runs whose exit code (column 4 of summary.tsv) is not 0, header line skipped.
failed="$(awk -F'\t' 'NR > 1 && $4 != 0' "${MATRIX_DIR}/summary.tsv" | wc -l)"
# A failed run has no usable result: say so, and exit 1 so calling scripts stop.
if (( failed > 0 )); then
    echo "ERROR: ${failed} run(s) failed (exit code != 0 in summary.tsv)." >&2
    exit 1
fi
