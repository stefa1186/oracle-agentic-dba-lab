#!/usr/bin/env bash
# =============================================================================
# 06_try_fix.sh
#
# Tests suggested changes by MEASURING them, never by estimate, and undoes
# every change straight after:
#
#   ./06_try_fix.sh advisor            SQL Tuning Advisor's scripted recommendations
#   ./06_try_fix.sh <file>.txt         fix lines written by hand (FIXES.md):
#                                      advisor_text_fixes.txt, dba_fixes.txt
#   ./06_try_fix.sh <run folder>       an agent run's REWRITE / DDL lines
#   ./06_try_fix.sh                    the most recent post 07 agent run
#
# What is measured (each as the application user, after a shared pool flush):
#   baseline     the original query, as it is
#   rewrite      the suggested rewrite (and: does it return the same result?)
#   ddl          the original query with the suggested indexes in place
#   ddl+rewrite  the rewrite with those indexes in place
#   profile      the original query with the advisor's SQL profile accepted
# Indexes are dropped and the profile removed right after their measurement,
# and again on exit, however the script ends (trap).
#
# Only checked changes are run (fix_lines.py): one SELECT as a rewrite,
# CREATE INDEX on the lab table, the advisor's own profile. Anything else is
# listed as rejected, never run.
#
# Saves output/post-07-sql-tuning/try_<label>.txt and the measurements.
# Run as the lab user.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-07 settings.
load_post07_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# ---- Which suggestions --------------------------------------------------------
source_arg="${1:-}"
if [[ "${source_arg}" == "advisor" ]]; then
    [[ -f "${POST07_OUT}/advisor_fixes.txt" ]] || die "no advisor fixes: run ./04_tuning_advisor.sh first."
    label="advisor"
    checked="$(python3 "${POST07_DIR}/fix_lines.py" --fixes "${POST07_OUT}/advisor_fixes.txt" --schema "${TUNE_SCHEMA}")"
elif [[ "${source_arg}" == *.txt ]]; then
    # A hand-written fix file, from this folder or a path.
    fixfile="${source_arg}"
    [[ -f "${fixfile}" ]] || fixfile="${POST07_DIR}/${source_arg}"
    [[ -f "${fixfile}" ]] || die "fix file not found: ${source_arg}"
    # A label from its name: advisor_text_fixes.txt -> advisor_text.
    label="$(basename "${fixfile}" .txt)"; label="${label%_fixes}"
    label="$(tr 'A-Z' 'a-z' <<< "${label}" | tr -c 'a-z0-9_\n-' '_')"
    checked="$(python3 "${POST07_DIR}/fix_lines.py" --fixes "${fixfile}" --schema "${TUNE_SCHEMA}")"
else
    run_dir="${source_arg}"
    if [[ -z "${run_dir}" ]]; then
        # The most recent post 07 agent run: <timestamp>/<model>/run-N.
        run_dir="$(ls -1d "${POST07_OUT}"/*/*/run-* 2>/dev/null | sort | tail -1 || true)"
        [[ -n "${run_dir}" ]] || die "no agent run found under ${POST07_OUT}. Run the agent first (see README)."
    fi
    [[ -f "${run_dir}/events.jsonl" ]] || die "${run_dir} has no events.jsonl: not a harness run folder."
    # A label from the run folder: agent_<timestamp>_run-N.
    label="agent_$(basename "$(dirname "$(dirname "${run_dir}")")")_$(basename "${run_dir}")"
    label="$(tr 'A-Z' 'a-z' <<< "${label}")"
    checked="$(python3 "${POST07_DIR}/fix_lines.py" --events "${run_dir}/events.jsonl" --schema "${TUNE_SCHEMA}")"
fi
summary="${POST07_OUT}/try_${label}.txt"

step "Suggested changes (${label})"
# Shown as checked: what will be run, and what won't.
while IFS=$'\t' read -r kind a b; do
    case "${kind}" in
        REWRITE)  info "REWRITE   ${a}" ;;
        DDL)      info "DDL       ${a}" ;;
        PROFILE)  info "PROFILE   SQL profile from advisor task ${a}" ;;
        REJECTED) warn "not tested (${a}): ${b}" ;;
    esac
done <<< "${checked}"

# The changes, by kind.
rewrite="$(awk -F'\t' '$1 == "REWRITE" { print $2 }' <<< "${checked}")"
mapfile -t ddls < <(awk -F'\t' '$1 == "DDL" { print $2 }' <<< "${checked}")
mapfile -t indexes < <(awk -F'\t' '$1 == "DDL" { print $3 }' <<< "${checked}")
profile_task="$(awk -F'\t' '$1 == "PROFILE" { print $2 }' <<< "${checked}")"

# ---- Undo, however this script ends --------------------------------------------
# Every index it may have created, and the profile, dropped. IF EXISTS: safe to repeat.
undo_changes() {
    local idx owner name sql=""
    for idx in "${indexes[@]:-}"; do
        [[ -n "${idx}" ]] || continue
        owner="${idx%%.*}"; name="${idx#*.}"
        sql+="drop index if exists \"${owner}\".\"${name}\";"$'\n'
    done
    db_sqlplus <<SQL >/dev/null 2>&1 || warn "undo failed: check for indexes and the profile POST07_PROFILE by hand."
alter session set container = FREEPDB1;
${sql}
begin dbms_sqltune.drop_sql_profile(name => 'POST07_PROFILE', ignore => true); end;
/
exit
SQL
}
trap undo_changes EXIT

# ---- Measuring -------------------------------------------------------------------
# One measurement: run it, print and record its summary line.
# Usage: measure_case <case name> <query file>
results=()
measure_case() {
    local name="$1" query="$2" out="${POST07_OUT}/measure_${label}_$1.txt"
    measure_query "${query}" "${out}"
    local line
    line="$(python3 "${POST07_DIR}/parse_measure.py" "${out}")"
    results+=("$(printf '%-12s %s' "${name}" "${line}")")
    info "${name}: ${line}"
}
# The result a query returned, for comparing a rewrite with the original.
result_of() { python3 "${POST07_DIR}/parse_measure.py" --fields "${POST07_OUT}/measure_${label}_$1.txt" | sed -n 's/^RESULT=//p'; }

step "1. Baseline: the original query"
measure_case baseline "${QUERY_ORIGINAL}"

rewrite_file=""
if [[ -n "${rewrite}" ]]; then
    step "2. The rewrite"
    rewrite_file="${POST07_OUT}/rewrite_${label}.sql"
    printf '%s;\n' "${rewrite}" > "${rewrite_file}"
    measure_case rewrite "${rewrite_file}"
fi

if (( ${#ddls[@]} > 0 )) && [[ -n "${ddls[0]}" ]]; then
    step "3. The suggested indexes, created for the measurement"
    for stmt in "${ddls[@]}"; do
        # Each statement in its own session; an Oracle error is reported, not fatal.
        out="$(db_sqlplus <<SQL 2>&1 || true
set feedback on
alter session set container = FREEPDB1;
alter session set current_schema = ${TUNE_SCHEMA};
${stmt};
exit
SQL
)"
        if grep -q 'ORA-' <<< "${out}"; then
            warn "Oracle refused: ${stmt} -> $(grep -m1 -o 'ORA-[0-9]*: .*' <<< "${out}")"
        else
            info "created: ${stmt}"
        fi
    done
    measure_case ddl "${QUERY_ORIGINAL}"
    [[ -n "${rewrite_file}" ]] && measure_case ddl+rewrite "${rewrite_file}"
    undo_changes
    info "indexes dropped again."
fi

if [[ -n "${profile_task}" ]]; then
    step "4. The advisor's SQL profile, accepted for the measurement"
    out="$(db_sqlplus <<SQL 2>&1 || true
alter session set container = FREEPDB1;
begin
    dbms_sqltune.accept_sql_profile(task_name => '${profile_task}', name => 'POST07_PROFILE', replace => true);
end;
/
exit
SQL
)"
    if grep -q 'ORA-' <<< "${out}"; then
        warn "Oracle refused the profile: $(grep -m1 -o 'ORA-[0-9]*: .*' <<< "${out}")"
    else
        measure_case profile "${QUERY_ORIGINAL}"
    fi
    undo_changes
    info "profile dropped again."
fi

step "Summary (${label})"
{
    printf '%s\n' "${results[@]}"
    # The rewrite must return what the original returns.
    if [[ -n "${rewrite_file}" ]]; then
        if [[ "$(result_of rewrite)" == "$(result_of baseline)" ]]; then
            echo "rewrite returns the same result as the original: yes"
        else
            echo "rewrite returns the same result as the original: NO ($(result_of rewrite) vs $(result_of baseline))"
        fi
    fi
} | tee "${summary}" | sed 's/^/    /'
info "Saved: ${summary}"
