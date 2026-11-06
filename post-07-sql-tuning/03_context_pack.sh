#!/usr/bin/env bash
# =============================================================================
# 03_context_pack.sh
#
# Builds what the agent gets: output/post-07-sql-tuning/context_pack.txt, the
# same material a developer would paste into a chat when asking for help:
#   1. the slow query, as the application runs it
#   2. its actual plan with runtime statistics (from 02_measure.sh)
#   3. the table and index DDL
#   4. the table, column and index statistics
# Every model gets exactly this file (the harness logs its SHA-256).
#
# Run as the lab user. Read-only.
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

# The plan comes from the original query's measurement.
measured="${POST07_OUT}/measure_original.txt"
[[ -f "${measured}" ]] || die "no measurement of the original query: run ./02_measure.sh first."

step "DDL and statistics of ${TUNE_SCHEMA}.ORDERS"
if ! meta="$(run_post07_sql context_pack.sql)"; then
    echo "${meta}" >&2
    die "reading the DDL and statistics failed."
fi
grep -q '#PACK_COMPLETE#' <<< "${meta}" || { echo "${meta}" >&2; die "unexpected output from SQL*Plus."; }

step "Writing the context pack"
{
    echo "=== The query (as the application runs it)"
    cat "${QUERY_ORIGINAL}"
    echo
    echo "=== Its actual execution plan, last of ${MEASURE_RUNS} runs (DBMS_XPLAN.DISPLAY_CURSOR, ALLSTATS LAST)"
    # The plan as DBMS_XPLAN printed it: from its first line to the end of its notes.
    sed -n '/^SQL_ID=/,/#MEASURE_COMPLETE#/p' "${measured}" | sed '1d' | grep -v '#MEASURE_COMPLETE#'
    echo
    # The DDL and statistics, without the end marker.
    grep -v '#PACK_COMPLETE#' <<< "${meta}"
} > "${CONTEXT_PACK}"
info "${CONTEXT_PACK}: $(wc -l < "${CONTEXT_PACK}") lines, $(wc -m < "${CONTEXT_PACK}") characters."
sed 's/^/    | /' "${CONTEXT_PACK}"

step "Done"
info "Next: ./04_tuning_advisor.sh, and the agent (see README)"
