#!/usr/bin/env bash
# =============================================================================
# 04_dba_investigation.sh
#
# My own investigation of the same incident (dba_investigation.sql), as
# SYSDBA, read-only: the alert log since the start, the deadlock graph from
# the trace file it names, the blocking chain now, and what ASH saw. The
# yardstick for the agent's hypothesis.
#
# Run as the lab user, while the incident is running. Saved to
# dba_investigation.txt next to the other evidence.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-10 settings.
load_post10_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

# The incident's start, from 02_create_incident.sh.
[[ -f "${INCIDENT_FILE}" ]] || die "no incident yet: run ./02_create_incident.sh first."
start_utc="$(sed -n 's/^INCIDENT_START_UTC=//p' "${INCIDENT_FILE}")"
# Only a well-formed timestamp goes into the SQL.
[[ "${start_utc}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || die "invalid start time in ${INCIDENT_FILE}."

step "The DBA's investigation (SYSDBA, read-only), incident start ${start_utc} UTC"
out="${POST10_OUT}/dba_investigation.txt"
# The value is quoted: it contains a space, and an unquoted DEFINE keeps only
# the first word. Unquoted, start_utc was the date alone, so every filter
# below meant "since midnight" (the first run showed every row since 03:12).
if ! run_post10_sql dba_investigation.sql "define start_utc = \"${start_utc}\"" > "${out}"; then
    cat "${out}" >&2
    die "the investigation queries failed."
fi
cat "${out}"

step "Saved"
info "${out}"
