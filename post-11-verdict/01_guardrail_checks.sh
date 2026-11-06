#!/usr/bin/env bash
# =============================================================================
# 01_guardrail_checks.sh
#
# Reruns every check in this series that involves NO model, in one go, and
# prints one line per check: the cage (post 01), OS commands (02), grants and
# SQL Firewall (03), the audit trail's tamper resistance and its FETCH FIRST
# blind spot (04), and the firewall bypass (09). Deterministic: the same lab
# gives the same lines, run after run.
#
# Each check is the post's own script, run unchanged; its full output goes to
# guardrails.txt in this post's output folder. The summary shows its exit code
# and its own result line. Exit code 1 is the expected result of
# 06_test_fetch_first.sh while the blind spot exists, so "PASS" here means
# "the script ran and said what it says", not "no finding".
#
# Oracle analogy: rerunning the security baseline after every change, instead
# of trusting that last quarter's report still holds.
#
# Run as the lab user, on the lab's resting state (every post's 99_cleanup.sh
# done: post 03's role, the firewall enforcing, post 04's audit policy on).
# Leaves the SQL Firewall enforcing.
# =============================================================================

# Stop on unset variables and pipeline failures. Not -e: one failing check
# must not stop the others.
set -uo pipefail

# Post 11's folder, and the repository root above it.
POST11_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${POST11_DIR}/.." && pwd)"
# Post 04's helpers (and through them posts 01-03): step, info, die, the lab user, the database.
# shellcheck source=../post-04-auditing-the-agent/lib.sh
source "${REPO_DIR}/post-04-auditing-the-agent/lib.sh"
# Read posts 01-04 settings.
load_post04_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# This post's evidence folder, and the full output of every check.
OUT_DIR="${OUTPUT_DIR}/post-11-verdict"
mkdir -p "${OUT_DIR}"
FULL="${OUT_DIR}/guardrails.txt"
: > "${FULL}"
# One summary line per check, collected here and printed at the end.
summary=()

# run_check "<what>" <post folder> <script> <grep pattern for its result line>
# Runs the script from its own folder, appends its output to guardrails.txt,
# and records: what, post, exit code, the last line matching the pattern.
run_check() {
    local what="$1" post="$2" script="$3" pattern="$4" out rc result raw
    step "${what} (${post}/${script})"
    # The script, from its own folder, as its README says. Its output goes to a
    # temporary file first, so $? is the script's own exit code.
    raw="$(mktemp)"
    (cd "${REPO_DIR}/${post}" && "./${script}") > "${raw}" 2>&1
    rc=$?
    # NUL characters (from audited SQL text) and SQLcl's startup chatter dropped.
    out="$(tr -d '\000' < "${raw}" \
          | grep -avE '^(Nov [0-9]|[A-Z][a-z]{2} [0-9]{2}, [0-9]{4}|INFO:|WARNING:|MCP Server|Press Ctrl|-{10,} MCP|-{30,}$|Server shutting)')"
    rm -f "${raw}"
    # The full output, for the record.
    { echo "################ ${post}/${script}  (exit ${rc})"; echo "${out}"; echo; } >> "${FULL}"
    # Its own result line: the last line matching the pattern.
    result="$(grep -aE "${pattern}" <<< "${out}" | tail -1 | sed -E 's/^ +//')"
    info "exit ${rc}: ${result:-(no result line)}"
    summary+=("$(printf "%-46s %-28s %4s  %s" "${what}" "${post}" "${rc}" "${result}")")
}

run_check "The cage: isolation, sudo, outbound policy" post-01-why-and-the-cage 03_verify.sh 'passed, .* failed'
run_check "SQLcl refuses OS commands at -R 4"          post-02-plugging-in-mcp 04_check_restrict.sh '^ *(PASS|FAIL):|BLOCKED|RAN'
run_check "Grants and SQL Firewall: 10 statements"     post-03-least-privilege 03_test_privileges.sh '^ *(PASS|FAIL):'
run_check "The agent cannot touch its audit trail"     post-04-auditing-the-agent 05_test_tamper.sh '^ *(PASS|FAIL|CHECK)'
run_check "FETCH FIRST and the audit policy"           post-04-auditing-the-agent 06_test_fetch_first.sh '^ *(PASS|FINDING|CHECK)'
run_check "Firewall bypass through SQLcl's own block"  post-09-breaking-it 06_firewall_bypass.sh 'the sleep RAN|Case 2'

# Post 09's bypass test leaves the firewall in observe mode: back to enforcing,
# the lab's resting state.
"${REPO_DIR}/post-03-least-privilege/04_sql_firewall.sh" enforce >/dev/null 2>&1 \
    || warn "could not set the SQL Firewall back to enforcing: run post-03-least-privilege/04_sql_firewall.sh enforce"

step "Summary"
printf '%-46s %-28s %4s  %s\n' "CHECK" "POST" "EXIT" "ITS OWN RESULT LINE"
printf '%s\n' "${summary[@]}"
echo
info "Full output: ${FULL}"
info "SQL Firewall: enforcing again."
