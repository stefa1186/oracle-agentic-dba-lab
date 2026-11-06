#!/usr/bin/env bash
# =============================================================================
# 01_check_awr.sh
#
# Checks, read-only, that this database can produce the AWR report the test
# needs:
#   - CONTROL_MANAGEMENT_PACK_ACCESS includes DIAGNOSTIC (AWR is usable)
#   - STATISTICS_LEVEL is TYPICAL or ALL (AWR collects)
#
# Licensing: Oracle's Database Licensing Information User Manual lists the
# Diagnostics Pack (AWR, ASH, ADDM) as an INCLUDED pack for Oracle AI Database
# Free. On Enterprise Edition it is an extra-cost option: check your licences
# before running this anywhere but a Free lab.
#
# Run as the lab user. Changes nothing. Exits non-zero if a check fails.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-06 settings.
load_post06_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

step "Edition and AWR settings"
# Read the values at instance level (the root).
values="$(db_sqlplus <<'SQL'
set heading off feedback off pagesize 0 linesize 200 tab off
select 'BANNER=' || banner_full from v$version;
select 'PACK_ACCESS=' || value from v$parameter where name = 'control_management_pack_access';
select 'STATISTICS_LEVEL=' || value from v$parameter where name = 'statistics_level';
exit
SQL
)"
# Pick each value out of the output.
banner="$(sed -n 's/^BANNER=//p' <<< "${values}" | head -1)"
pack="$(sed -n 's/^PACK_ACCESS=//p' <<< "${values}")"
stats="$(sed -n 's/^STATISTICS_LEVEL=//p' <<< "${values}")"
info "${banner}"
info "control_management_pack_access = ${pack}"
info "statistics_level               = ${stats}"

step "Checks"
failed=0
# AWR needs the Diagnostics Pack enabled.
if [[ "${pack}" == *DIAGNOSTIC* ]]; then
    info "PASS: Diagnostics Pack access enabled (AWR usable)."
else
    warn "FAIL: control_management_pack_access is '${pack}': AWR reports need DIAGNOSTIC."
    failed=1
fi
# AWR collects nothing useful at BASIC.
if [[ "${stats}" == "TYPICAL" || "${stats}" == "ALL" ]]; then
    info "PASS: statistics_level ${stats}."
else
    warn "FAIL: statistics_level is '${stats}': AWR needs TYPICAL or ALL."
    failed=1
fi

# Licensing, always shown: the check passing doesn't mean you're licensed.
step "Licensing"
if [[ "${banner}" == *Free* ]]; then
    info "Oracle AI Database Free: the Diagnostics Pack is an included pack (Database Licensing Information User Manual)."
else
    warn "not a Free edition: on Enterprise Edition, AWR is part of the extra-cost Diagnostics Pack. Check your licences."
fi

(( failed == 0 )) || die "fix the failed checks before generating the load."
step "Done"
info "Next: ./02_generate_load.sh"
