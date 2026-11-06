#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 12): sourced by the post 12 scripts, not executed.
#
# Reuses post 04's helpers (and through them posts 01-03: settings, lab user,
# db_sqlplus, the audit export, the network policy's names) and adds the
# post 12 settings and helpers.
# =============================================================================

# Folder of the post 12 scripts.
POST12_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 04 helpers (and posts 01-03 through them).
# shellcheck source=../post-04-auditing-the-agent/lib.sh
source "${POST12_DIR}/../post-04-auditing-the-agent/lib.sh"

# The harness, and its local-model scripts (the Ollama container).
HARNESS_DIR="$(cd "${POST12_DIR}/../agent-harness" && pwd)"
OLLAMA_DIR="${HARNESS_DIR}/local-models"

# Post 08's folder (runbooks, questions, search) and its evidence folder,
# where its 04_search.sh writes the files the agent gets in test B.
POST08_DIR="$(cd "${POST12_DIR}/../post-08-vector-search-runbooks" && pwd)"
POST08_OUT="${OUTPUT_DIR}/post-08-vector-search-runbooks"

# The two tests, with prompts reused UNCHANGED from earlier posts:
#   test A: post 02's first-session prompt (the agent queries the database)
#   test B: post 08's runbook questions (no tools: question + runbook excerpts)
INVENTORY_PROMPT="$(cd "${POST12_DIR}/../post-02-plugging-in-mcp" && pwd)/05_prompt.md"
RUNBOOK_PROMPT="${POST08_DIR}/05_prompt.md"

# Where this post keeps its evidence. The harness files this post's runs here
# too (run_matrix.sh -o), like any post's: <timestamp>/<model>/run-N. The two
# tests are told apart by their prompt (post 02's or post 08's).
OUTPUT_GROUP="post-12-offline-local-models"
POST12_OUT="${OUTPUT_DIR}/${OUTPUT_GROUP}"
# Test A's answer key, from the database itself (written by 02_prepare_online.sh).
ANSWER_KEY="${POST12_OUT}/answer_key.txt"
# The policy's drop counter when the local runs started (written by 05_run_local.sh).
COUNTER_FILE="${POST12_OUT}/offline_counter_start.txt"

# Load posts 01-04 settings, then post 12 settings and Ollama's.
load_post12_config() {
    # Everything from posts 01-04.
    load_post04_config
    # Post 12 defaults.
    # shellcheck source=env.example
    source "${POST12_DIR}/env.example"
    # Post 12 local overrides, if any.
    if [[ -f "${POST12_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST12_DIR}/.env"
    fi
    # Ollama's settings (container name, port, image), shared with local-models/.
    # shellcheck source=../agent-harness/local-models/ollama.conf
    source "${OLLAMA_DIR}/ollama.conf"
    # At least one model of each kind.
    [[ -n "${CLOUD_MODELS// /}" ]] || die "CLOUD_MODELS is empty."
    [[ -n "${LOCAL_MODELS// /}" ]] || die "LOCAL_MODELS is empty."
    # Every local model must be pinned: no unpinned model is ever pulled.
    local tag
    for tag in ${LOCAL_MODELS}; do
        [[ -n "$(pin_digest "${tag}")" ]] || die "${tag} has no line in ${POST12_DIR}/model_pins.txt."
    done
    # Numbers: whole numbers in a sensible range.
    [[ "${TEST_MAX_TOOL_OUTPUT_CHARS}" =~ ^[0-9]+$ ]] && (( TEST_MAX_TOOL_OUTPUT_CHARS >= 1000 )) \
        || die "TEST_MAX_TOOL_OUTPUT_CHARS must be a whole number, at least 1000."
    [[ "${TEST_MAX_STEPS}" =~ ^[0-9]+$ ]] && (( TEST_MAX_STEPS >= 1 && TEST_MAX_STEPS <= 100 )) \
        || die "TEST_MAX_STEPS must be a whole number from 1 to 100."
    [[ "${TEST_REQUEST_TIMEOUT}" =~ ^[0-9]+$ ]] && (( TEST_REQUEST_TIMEOUT >= 60 )) \
        || die "TEST_REQUEST_TIMEOUT must be a whole number of seconds, at least 60."
    [[ "${TEST_LOCAL_MODEL_RETRIES}" =~ ^[0-9]+$ ]] \
        || die "TEST_LOCAL_MODEL_RETRIES must be a whole number."
    # Thinking: empty (the server's default) or one of the usual levels.
    local effort
    for effort in "${TEST_CLOUD_REASONING_EFFORT}" "${TEST_LOCAL_REASONING_EFFORT}"; do
        [[ "${effort}" =~ ^(|none|low|medium|high)$ ]] \
            || die "TEST_CLOUD_REASONING_EFFORT and TEST_LOCAL_REASONING_EFFORT must be empty, none, low, medium or high."
    done
    [[ "${RAM_FACTOR_PERCENT}" =~ ^[0-9]+$ ]] && (( RAM_FACTOR_PERCENT >= 100 )) \
        || die "RAM_FACTOR_PERCENT must be a whole number, at least 100."
    # The evidence folder exists from here on.
    mkdir -p "${POST12_OUT}"
}

# The pinned manifest digest of a local model (from model_pins.txt), or nothing.
# Usage: pin_digest <tag>
pin_digest() {
    awk -v t="$1" '!/^#/ && $1 == t { print $2 }' "${POST12_DIR}/model_pins.txt"
}

# The pinned size in bytes of a local model (from model_pins.txt), or nothing.
# Usage: pin_bytes <tag>
pin_bytes() {
    awk -v t="$1" '!/^#/ && $1 == t { print $3 }' "${POST12_DIR}/model_pins.txt"
}

# A pull log, readable: "ollama pull" redraws its progress bar with terminal
# control codes (back to column 1, erase the line) instead of new lines, so the
# raw log is one endless line. Each redraw becomes a line of its own, the codes
# are dropped, trailing spaces and blank lines too.
# Usage: readable_log <file>
readable_log() {
    sed -E 's/\x1b\[1G/\n/g; s/\x1b\[[0-9;?]*[A-Za-z]//g' "$1" | tr '\r' '\n' | sed -E 's/[[:space:]]+$//' | grep -v '^$'
}

# GET one path of the Ollama API (on 127.0.0.1 only) and print the answer.
# Usage: ollama_get /api/tags
ollama_get() {
    curl -fsS --max-time 30 "http://127.0.0.1:${OLLAMA_PORT}$1"
}

# The digest of a model as the local Ollama server has it, or nothing if the
# model isn't there (or the server isn't running).
# Usage: local_digest <tag>
local_digest() {
    { ollama_get /api/tags 2>/dev/null || true; } | python3 -c '
# Print the digest of the model whose name is the tag given as argument
# (nothing when the server gave no answer).
import json, sys
tag, text = sys.argv[1], sys.stdin.read()
for m in (json.loads(text).get("models", []) if text.strip() else []):
    if m.get("name") == tag:
        print(m.get("digest", ""))
' "$1"
}

# The fixed request of probe_model: no knowledge needed, and the right answer
# is obvious. Like "select level from dual connect by level <= 20" as a smoke
# test: it proves the path works, and it is long enough to time.
PROBE_PROMPT="Count from 1 to 20, separated by commas. Write nothing else."

# Run one local model once, on PROBE_PROMPT, through Ollama's own API
# (/api/chat, on 127.0.0.1), and print its answer and what the answer cost, as
# Ollama measured it: the tokens written and the time spent writing them, and
# the time to load the model into memory (zero when it was loaded already).
# Thinking is switched off for this request, when the model has it, so the
# answer comes at once. Temperature 0 and a fixed seed: the same answer every
# time. Proves the model RUNS, not just that the server lists it.
# Usage: probe_model <tag>
probe_model() {
    local tag="$1" caps body answer
    # The model's capabilities (e.g. completion, tools, thinking).
    caps="$(curl -fsS --max-time 60 -H 'Content-Type: application/json' \
                -d "$(python3 -c 'import json, sys; print(json.dumps({"model": sys.argv[1]}))' "${tag}")" \
                "http://127.0.0.1:${OLLAMA_PORT}/api/show" \
            | python3 -c 'import json, sys; print(" ".join(json.load(sys.stdin).get("capabilities") or []))')"
    # The request, built with Python's json module (quoting always right).
    body="$(python3 - "${tag}" "${PROBE_PROMPT}" "${caps}" <<'PY'
# Arguments: the model, the prompt, its capabilities (space-separated).
import json, sys
tag, prompt, caps = sys.argv[1], sys.argv[2], sys.argv[3].split()
req = {"model": tag, "messages": [{"role": "user", "content": prompt}], "stream": False,
       "options": {"temperature": 0, "seed": 42}}
# No thinking for this one request, if the model thinks at all.
if "thinking" in caps:
    req["think"] = False
print(json.dumps(req))
PY
)"
    # Send it (a cold load of a large model from disk takes a while), then
    # print the answer on one line, and the numbers.
    curl -fsS --max-time 900 -H 'Content-Type: application/json' -d "${body}" \
        "http://127.0.0.1:${OLLAMA_PORT}/api/chat" | python3 -c '
# Ollama reports durations in nanoseconds; eval = writing the answer.
import json, sys
r = json.load(sys.stdin)
answer = " ".join((r.get("message", {}).get("content") or "").split())
wrote, secs = r.get("eval_count", 0), r.get("eval_duration", 0) / 1e9
load = r.get("load_duration", 0) / 1e9
rate = wrote / secs if secs else 0
print(f"answer:  {answer[:72]}")
print(f"speed:   wrote {wrote} tokens in {secs:.1f} s = {rate:.1f} tokens/s (model load: {load:.1f} s)")
'
}

# The lab user's network mode, from the root-owned policy (post 01), read with
# the one read-only sudo rule post 01 installed: "online", "offline", or
# "unknown" (a policy written before post 12, without the mode in it).
egress_mode() {
    local rules
    rules="$(sudo -n /usr/sbin/nft list table inet "${EGRESS_TABLE}" 2>/dev/null)" || { echo "unknown"; return; }
    # The last rule's comment names the mode (00_root_setup.sh writes it).
    grep -o 'lab user: mode [a-z]*' <<< "${rules}" | awk '{ print $NF }' | grep . || echo "unknown"
}

# How many packets the policy has dropped for the lab user so far (the counter
# of its last rule), or nothing if it can't be read.
drop_counter() {
    { sudo -n /usr/sbin/nft list table inet "${EGRESS_TABLE}" 2>/dev/null || true; } \
        | awk '/lab user: mode/ { for (i = 1; i < NF; i++) if ($i == "packets") print $(i + 1) }'
}

# Runs of this script that ended with an error (run_tests counts them).
FAILED_RUNS=0

# Run BOTH tests for ONE model, through the harness's matrix:
#   test A: post 02's prompt, with tools (one run)
#   test B: post 08's prompt, no tools, once per question, without and with
#           the runbook excerpts (six runs)
# The same limits for every model (TEST_* settings), passed through the
# environment, so only the model changes. Two settings differ by where the
# model runs: retries after a temporary error (local: TEST_LOCAL_MODEL_RETRIES;
# cloud: the harness's own MODEL_RETRIES) and thinking (TEST_LOCAL_ and
# TEST_CLOUD_REASONING_EFFORT, always passed, so agent-harness/.env can't
# change them).
# A run that ends with an error (the model didn't answer in time, the
# endpoint failed) is a result, not the end of the test: run_matrix.sh exits
# 1 for it, run_tests counts it in FAILED_RUNS and goes on with the next run.
# Usage: run_tests <openrouter|local> <model>
run_tests() {
    local provider="$1" model="$2" safe models_file id kind file
    # A one-line models file for run_matrix.sh: this provider, this model.
    safe="$(sed 's/[^A-Za-z0-9.-]\+/_/g' <<< "${provider}_${model}")"
    models_file="${POST12_OUT}/models_${safe}.txt"
    printf '%s %s\n' "${provider}" "${model}" > "${models_file}"
    # The settings of every run of this model (see above).
    local settings=(MAX_TOOL_OUTPUT_CHARS="${TEST_MAX_TOOL_OUTPUT_CHARS}" MAX_STEPS="${TEST_MAX_STEPS}"
                    REQUEST_TIMEOUT="${TEST_REQUEST_TIMEOUT}")
    if [[ "${provider}" == "local" ]]; then
        settings+=(MODEL_RETRIES="${TEST_LOCAL_MODEL_RETRIES}" REASONING_EFFORT="${TEST_LOCAL_REASONING_EFFORT}")
    else
        settings+=(REASONING_EFFORT="${TEST_CLOUD_REASONING_EFFORT}")
    fi

    step "Test A, ${model}: post 02's first-session prompt (with tools)"
    ( cd "${HARNESS_DIR}" && env "${settings[@]}" \
          ./run_matrix.sh -m "${models_file}" -o "${OUTPUT_GROUP}" "${INVENTORY_PROMPT}" -- --final-on-limit ) \
        || failed_run "Test A, ${model}"

    # Post 08's question IDs, in the file's order (Q lines: "Q | <id> | ...").
    for id in $(awk -F'|' '$1 ~ /^Q / { gsub(/ /, "", $2); print $2 }' "${POST08_DIR}/questions.txt"); do
        for kind in question context; do
            file="${POST08_OUT}/${kind}_${id}.txt"
            [[ -f "${file}" ]] || die "no ${file}: run ./02_prepare_online.sh first."
            step "Test B, ${model}: question '${id}', $( [[ "${kind}" == question ]] && echo 'WITHOUT' || echo 'WITH') runbooks"
            ( cd "${HARNESS_DIR}" && env "${settings[@]}" \
                  ./run_matrix.sh -m "${models_file}" -o "${OUTPUT_GROUP}" "${RUNBOOK_PROMPT}" \
                      -- --attach "${file}" --allow-tools NONE ) \
                || failed_run "Test B, ${model}, question '${id}' (${kind})"
        done
    done
}

# Count a run that ended with an error, say so, and let the test go on.
# Usage: failed_run <which run>
failed_run() {
    FAILED_RUNS=$(( FAILED_RUNS + 1 ))
    warn "$1: the run ended with an error (its log says why). It is kept as a result; the next run starts."
}

# Write the SQL Firewall violations of the agent's user between two UTC
# timestamps ("YYYY-MM-DD HH:MM:SS.ffffff"), widened by AUDIT_WINDOW_MARGIN,
# to stdout: one JSON object per line, built by the database (JSON_OBJECT).
# (The same query as post 09's, kept here so post 12 stands on its own.)
fetch_violations_jsonl() {
    local start="$1" end="$2" ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$'
    # Only well-formed timestamps go into the SQL.
    [[ "${start}" =~ ${ts_re} && "${end}" =~ ${ts_re} ]] || die "invalid time window: '${start}' .. '${end}'"
    db_sqlplus <<SQL
set feedback off heading off pagesize 0 linesize 32767 trimspool on tab off
alter session set container = FREEPDB1;
-- Write the firewall's in-memory log entries to disk first, so the list is complete.
exec dbms_sql_firewall.flush_logs
-- One line per statement outside the allow-list: when, and the statement.
select json_object(
         'TS'     value to_char(sys_extract_utc(occurred_at), 'YYYY-MM-DD HH24:MI:SS.FF6'),
         'ACTION' value firewall_action,
         'SQL'    value dbms_lob.substr(sql_text, 1500, 1)
         returning varchar2(4000))
from   dba_sql_firewall_violations
where  username = '${AGENT_DB_USER}'
and    sys_extract_utc(occurred_at)
       between to_timestamp('${start}', 'YYYY-MM-DD HH24:MI:SS.FF6') - numtodsinterval(${AUDIT_WINDOW_MARGIN}, 'SECOND')
           and to_timestamp('${end}',   'YYYY-MM-DD HH24:MI:SS.FF6') + numtodsinterval(${AUDIT_WINDOW_MARGIN}, 'SECOND')
order  by occurred_at;
exit
SQL
}
