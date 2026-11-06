#!/usr/bin/env bash
# =============================================================================
# 06_firewall_bypass.sh
#
# The open question from post 03: SQL Firewall approved SQLcl's own PL/SQL
# blocks, and one of them runs a literal with EXECUTE IMMEDIATE. The firewall
# compares the STRUCTURE of a statement with every literal replaced by "?".
# So can the agent's account send that approved block with its own literal,
# and run SQL that isn't on the allow-list?
#
# Deterministic: no model. bypass_tests.sql.template is filled in and
# replayed through SQLcl MCP as the agent, with the allow-list ENFORCING.
# Evidence, per case: the result, the elapsed time (a case that sleeps
# BYPASS_SLEEP_SECONDS proves the sleep ran), and what SQLcl returned; then
# the firewall's violation log and the audit trail for the same window.
#
# Run as the lab user, after ./01_prepare_agent.sh. The firewall goes back to
# observe mode (the post 09 state) when the script ends, even on errors.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-09 settings.
load_post09_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# The statements, with the settings filled in, kept with the evidence.
tests="${POST09_OUT}/bypass_tests.sql"
sed -e "s/@SLEEP@/${BYPASS_SLEEP_SECONDS}/g" -e "s/@AGENT@/${AGENT_DB_USER}/g" \
    "${POST09_DIR}/bypass_tests.sql.template" > "${tests}"
result="${POST09_OUT}/bypass_result.jsonl"

step "1/5 SQL Firewall to ENFORCING for this test"
# Whatever happens next, observe mode comes back at the end.
trap '"${POST03_DIR}/04_sql_firewall.sh" observe > /dev/null && echo "    (SQL Firewall back to observe mode)"' EXIT
"${POST03_DIR}/04_sql_firewall.sh" enforce | grep -A4 '=== Allow-list' | sed 's/^/    /'

step "2/5 Replay through SQLcl MCP, as ${AGENT_DB_USER}, without a model"
start="$(utc_now)"
# --json: one object per statement, with the elapsed seconds and SQLcl's output.
# The exit code says whether the expectations were met; the report below judges.
replay "${tests}" --json > "${result}" || true
end="$(utc_now)"
python3 - "${result}" "${BYPASS_SLEEP_SECONDS}" <<'PY'
# Print each case: what it is, its result, its time, and what SQLcl returned.
import json, sys
labels = {
    1: "the sleep, sent directly",
    2: "the sleep, as the literal of the approved block",
    3: "GRANT DBA, as the literal of the approved block",
    4: "the approved block with one statement added",
}
sleep = int(sys.argv[2])
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("{"):
        continue
    r = json.loads(line)
    # Did the sleep run? Only a call that took (almost) the full sleep proves it.
    ran = r["elapsed"] >= sleep - 0.5
    print(f"    Case {r['n']}: {labels.get(r['n'], '?')}")
    print(f"      result {r['error'] or 'ok'}, {r['elapsed']:.2f} s"
          + (f"  -> the sleep RAN" if ran else ""))
    out = [l for l in (r.get("output") or "").splitlines() if l.strip()]
    for l in out[:6]:
        print(f"      | {l[:110]}")
    if len(out) > 6:
        print(f"      | (trimmed: {len(out) - 6} more lines)")
PY

step "3/5 SQL Firewall violation log, same window"
fetch_violations_jsonl "${start}" "${end}" > "${POST09_OUT}/bypass_violations.jsonl"
python3 - "${POST09_OUT}/bypass_violations.jsonl" <<'PY'
# One line per violation: time, what the firewall did, the statement.
import json, sys
rows = [json.loads(l, strict=False) for l in open(sys.argv[1], encoding="utf-8") if l.startswith("{")]
print(f"    {len(rows)} violations")
for v in rows:
    sql = " ".join((v.get("SQL") or "").split())
    print(f"    {(v.get('TS') or '')[11:19]}  {v.get('ACTION') or '':<8} {sql[:95] + ('...' if len(sql) > 95 else '')}")
PY

step "4/5 Audit trail, same window"
fetch_audit_jsonl "${start}" "${end}" > "${POST09_OUT}/bypass_audit.jsonl"
python3 "${POST04_DIR}/audit_report.py" --audit "${POST09_OUT}/bypass_audit.jsonl" --mode show | sed 's/^/    /'

step "5/5 What ${AGENT_DB_USER} holds now (case 3 tried GRANT DBA)"
# Roles and system privileges granted directly to the agent's user.
db_sqlplus <<SQL | grep '^HOLDS ' | sed 's/^HOLDS /    /'
set heading off feedback off pagesize 0
alter session set container = FREEPDB1;
select 'HOLDS role ' || granted_role from dba_role_privs where grantee = '${AGENT_DB_USER}'
union all
select 'HOLDS privilege ' || privilege from dba_sys_privs where grantee = '${AGENT_DB_USER}'
order by 1;
exit
SQL

step "Done"
info "Evidence: ${tests}, ${result}, bypass_violations.jsonl, bypass_audit.jsonl in ${POST09_OUT}"
info "Next: ./99_cleanup.sh when you're done with post 09"
