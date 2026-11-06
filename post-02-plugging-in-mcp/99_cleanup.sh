#!/usr/bin/env bash
# =============================================================================
# 99_cleanup.sh
#
# Undoes post 02. Two levels:
#
#   ./99_cleanup.sh --agent      drops the AI_AGENT database user and its
#                                password file. SQLcl stays installed.
#   ./99_cleanup.sh --all        also removes SQLcl, its saved connections
#                                (~/.dbtools) and the cached download.
#
# Run as the lab user. Asks for confirmation unless --yes is added.
# Safe to rerun: anything already gone is skipped.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01 and post 02 settings.
load_post02_config
# Must be the lab user, in a proper login session.
require_lab_user

# Usage text, shown on wrong arguments.
usage() { echo "Usage: $0 --agent|--all [--yes]" >&2; exit 1; }

# Parse: exactly one level, optionally --yes.
level=""
assume_yes=0
for arg in "$@"; do
    case "${arg}" in
        --agent) level="agent" ;;
        --all)   level="all" ;;
        --yes)   assume_yes=1 ;;
        *)       usage ;;
    esac
done
[[ -n "${level}" ]] || usage

# Confirmation: type "cleanup".
if (( ! assume_yes )); then
    # Describe exactly what this level removes.
    what="database user ${AGENT_DB_USER}"
    [[ "${level}" == "all" ]] && what="${what}, SQLcl and its saved connections"
    read -r -p "This removes: ${what}. Type 'cleanup' to confirm: " answer
    [[ "${answer}" == "cleanup" ]] || die "not confirmed; nothing was changed."
fi

step "Dropping ${AGENT_DB_USER}"
if [[ "$(pdb_open_mode)" == "READWRITE" ]]; then
    # Drop the user (and anything it owns) only if it exists.
    db_sqlplus <<SQL >/dev/null
whenever sqlerror exit failure
alter session set container = FREEPDB1;
declare
    l_count number;
begin
    select count(*) into l_count from dba_users where username = '${AGENT_DB_USER}';
    if l_count > 0 then
        execute immediate 'drop user ${AGENT_DB_USER} cascade';
    end if;
end;
/
exit
SQL
    info "${AGENT_DB_USER} dropped (if it existed)."
else
    # Database down: nothing to drop now; a fresh database won't have it either.
    warn "FREEPDB1 is not open; the database user was not touched."
fi
# Remove its password file.
rm -f "${AGENT_PASSWORD_FILE}"
info "Agent password file removed."

if [[ "${level}" == "all" ]]; then
    step "Removing SQLcl"
    # The program, its PATH link, the saved connections and the cached zip.
    rm -rf "${SQLCL_DIR}" "${HOME}/.dbtools" "${HOME}/.cache/oralab/sqlcl.zip"
    rm -f "${HOME}/.local/bin/sql"
    info "SQLcl, saved connections and cached download removed."
fi

step "Done"
