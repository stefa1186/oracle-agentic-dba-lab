#!/usr/bin/env bash
# =============================================================================
# 01_setup.sh
#
# Prepares post 07:
#   1. checks that the Tuning Pack is enabled (SQL Tuning Advisor), and says
#      what the licence situation is
#   2. creates the application user TUNE_LAB with a new random password
#      (kept in ~/.config/oralab/tune_lab_pwd, mode 600, until 99_cleanup.sh)
#   3. builds ORDERS (1,000,000 rows by default), its indexes and statistics
#
# Licensing: Oracle's Database Licensing Information User Manual lists the
# Tuning Pack as included for Oracle AI Database Free. On Enterprise Edition
# it is an extra-cost option (and requires the Diagnostics Pack).
#
# Run as the lab user. SQL runs as SYSDBA inside the container (no password).
# Deterministic: rerunning drops and rebuilds everything, with a new password.
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

step "1/3 Tuning Pack"
values="$(db_sqlplus <<'SQL'
set heading off feedback off pagesize 0 linesize 200 tab off
select 'BANNER=' || banner_full from v$version;
select 'PACK_ACCESS=' || value from v$parameter where name = 'control_management_pack_access';
exit
SQL
)"
banner="$(sed -n 's/^BANNER=//p' <<< "${values}" | head -1)"
pack="$(sed -n 's/^PACK_ACCESS=//p' <<< "${values}")"
info "${banner}"
info "control_management_pack_access = ${pack}"
# SQL Tuning Advisor needs TUNING access.
[[ "${pack}" == *TUNING* ]] || die "control_management_pack_access is '${pack}': SQL Tuning Advisor needs DIAGNOSTIC+TUNING."
info "PASS: Tuning Pack access enabled (SQL Tuning Advisor usable)."
if [[ "${banner}" == *Free* ]]; then
    info "Oracle AI Database Free: the Tuning Pack is included (Database Licensing Information User Manual)."
else
    warn "not a Free edition: on Enterprise Edition the Tuning Pack is an extra-cost option. Check your licences."
fi

step "2/3 The application user ${TUNE_SCHEMA}"
# A new password for every setup: "Tl" + 30 random hex characters.
mkdir -p "$(dirname "${TUNE_PWD_FILE}")"
chmod 700 "$(dirname "${TUNE_PWD_FILE}")"
# Created with mode 600 from the start (umask), never readable by anyone else.
( umask 077; echo "Tl$(od -An -N15 -tx1 /dev/urandom | tr -d ' \n')" > "${TUNE_PWD_FILE}" )
info "Password kept in ${TUNE_PWD_FILE} (mode 600)."

step "3/3 ORDERS: ${TUNE_ROWS} rows, indexes, statistics (a minute or two)"
if ! output="$(run_post07_sql setup_schema.sql "define tune_pwd = $(tune_password)")"; then
    # verify is off in the SQL file: the password is not in this output.
    echo "${output}" >&2
    die "setup failed."
fi
grep -q SCHEMA_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
grep '^ROWS=' <<< "${output}" | sed 's/^/    /'

step "Done"
info "The slow query: ${QUERY_ORIGINAL}"
sed 's/^/    | /' "${QUERY_ORIGINAL}"
info "Next: ./02_measure.sh"
