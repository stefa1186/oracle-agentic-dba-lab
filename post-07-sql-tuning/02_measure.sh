#!/usr/bin/env bash
# =============================================================================
# 02_measure.sh
#
# Measures a query the only way that counts: by running it. As the
# application user, after a shared pool flush, MEASURE_RUNS times; the last
# execution's actual plan, buffer gets and time are kept.
#
#   ./02_measure.sh                         the slow query (query_original.sql)
#   ./02_measure.sh <query file> <label>    any other query, e.g. a rewrite
#
# Saves output/post-07-sql-tuning/measure_<label>.txt (raw: results, plan)
# and prints the summary.
#
# Run as the lab user. Reads data only; flushes FREEPDB1's shared pool (lab only).
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

# Which query, and what to call this measurement.
query="${1:-${QUERY_ORIGINAL}}"
label="${2:-original}"
[[ "${label}" =~ ^[a-z0-9_-]+$ ]] || die "label: lower case letters, digits, '_' and '-' only."
out="${POST07_OUT}/measure_${label}.txt"

step "Measuring '${label}' (${MEASURE_RUNS} runs, the last one kept)"
measure_query "${query}" "${out}"
# The plan, exactly as DBMS_XPLAN printed it.
sed -n '/^SQL_ID=/,/#MEASURE_COMPLETE#/p' "${out}" | grep -v '#MEASURE_COMPLETE#' | sed 's/^/    /'

step "Summary"
info "$(python3 "${POST07_DIR}/parse_measure.py" "${out}")"
info "Saved: ${out}"
