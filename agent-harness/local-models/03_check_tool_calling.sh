#!/usr/bin/env bash
# =============================================================================
# 03_check_tool_calling.sh
#
# Checks that a local model can actually call tools through the
# OpenAI-compatible API, before spending time on a real test.
#
# It offers the model one harmless fake tool ("get_db_version") and asks a
# question that needs it. PASS means the model answered with a well-formed
# tool call. Nothing touches the database.
#
# Oracle analogy: a "select 1 from dual" for the agent: proves the path works
# before you run anything that matters.
#
# Usage:
#   ./03_check_tool_calling.sh <model> [<model> ...]
#
# Safe to run any number of times: it changes nothing.
# =============================================================================

# Stop on errors, unset variables and pipeline failures.
set -euo pipefail

# Folder of this script, so it works from any current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load the shared settings (port, ...).
# shellcheck source=ollama.conf
source "${SCRIPT_DIR}/ollama.conf"

# At least one model name is required.
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <model> [<model> ...]" >&2
    exit 1
fi

# OpenAI-compatible chat endpoint of the local server.
URL="http://127.0.0.1:${OLLAMA_PORT}/v1/chat/completions"
# Overall result: 0 if every model passes, 1 if any fails.
overall=0

# Test each model given on the command line.
for model in "$@"; do
    # Build the request body with Python's json module, so the model name is
    # always quoted correctly whatever characters it contains.
    body="$(python3 - "${model}" <<'PY'
# Read the model name passed as the first argument.
import json, sys
model = sys.argv[1]
# One fake tool with no parameters, and a question that requires it.
print(json.dumps({
    "model": model,
    "temperature": 0,
    "messages": [{"role": "user", "content": "What is the database version? Use the available tool."}],
    "tools": [{"type": "function", "function": {
        "name": "get_db_version",
        "description": "Returns the Oracle database version.",
        "parameters": {"type": "object", "properties": {}}}}],
}))
PY
)"
    # Send the request; allow up to 10 minutes for a cold model load on CPU.
    echo -n "${model}: "
    if ! response="$(curl -fsS --max-time 600 -H 'Content-Type: application/json' -d "${body}" "${URL}")"; then
        # The server refused or failed (unknown model, out of memory, ...).
        echo "FAIL (request error; is the model pulled?)"
        overall=1
        continue
    fi
    # Inspect the answer: PASS only if the first choice contains a call to our tool.
    verdict="$(python3 -c '
# Parse the JSON response from stdin.
import json, sys
r = json.load(sys.stdin)
# Tool calls of the first choice, if any.
calls = (r.get("choices") or [{}])[0].get("message", {}).get("tool_calls") or []
# PASS if one of them names our tool.
print("PASS" if any(c.get("function", {}).get("name") == "get_db_version" for c in calls) else "FAIL (answered without calling the tool)")
' <<< "${response}")"
    # Print the verdict for this model.
    echo "${verdict}"
    # Remember any failure for the exit code.
    [[ "${verdict}" == PASS ]] || overall=1
done

# Exit 0 only if every model passed, so the script can gate other scripts.
exit "${overall}"
