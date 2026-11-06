#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 03): sourced by the post 03 scripts, not executed.
#
# Reuses post 02's helpers (which reuse post 01's) and adds the post 03
# settings, plus the deterministic replay tool from the agent harness.
# =============================================================================

# Folder of the post 03 scripts.
POST03_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 02 helpers (and through them post 01's): settings, lab user, db_sqlplus ...
# shellcheck source=../post-02-plugging-in-mcp/lib.sh
source "${POST03_DIR}/../post-02-plugging-in-mcp/lib.sh"

# The agent harness: its Python environment runs the replay tool.
HARNESS_DIR="$(cd "${POST03_DIR}/../agent-harness" && pwd)"
HARNESS_PYTHON="${HARNESS_DIR}/.venv/bin/python"

# Load posts 01-02 settings, then post 03 settings.
load_post03_config() {
    # Lab, database, SQLcl and agent settings.
    load_post02_config
    # Post 03 defaults.
    # shellcheck source=env.example
    source "${POST03_DIR}/env.example"
    # Post 03 local overrides, if any.
    if [[ -f "${POST03_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST03_DIR}/.env"
    fi
    # Role and profile names: plain Oracle identifiers, safe inside SQL.
    [[ "${AGENT_ROLE}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]]    || die "AGENT_ROLE must be an upper-case Oracle identifier."
    [[ "${AGENT_PROFILE}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "AGENT_PROFILE must be an upper-case Oracle identifier."
    # Profile limits: whole numbers only.
    local v
    for v in PROFILE_SESSIONS_PER_USER PROFILE_CPU_PER_CALL PROFILE_LOGICAL_READS_PER_CALL \
             PROFILE_IDLE_TIME PROFILE_CONNECT_TIME PROFILE_FAILED_LOGIN_ATTEMPTS; do
        [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "${v} must be a positive whole number."
    done
}

# Read granted_views.txt: one upper-case SYS object name per line, comments
# and blank lines skipped. Prints the names, one per line, sorted, no duplicates.
#
# EXTRA_VIEW_FILES (optional, space-separated absolute paths) adds more lists
# in the same format, for a test that deliberately needs a wider view
# (post 05: health_check_views.txt). Unset, only granted_views.txt is read,
# so the post 03 state is always one rerun of 01_least_privilege.sh away.
read_granted_views() {
    local name file
    # The base list is always included.
    local files=("${POST03_DIR}/granted_views.txt")
    # Add the extra lists, if any were given.
    if [[ -n "${EXTRA_VIEW_FILES:-}" ]]; then
        local extra=()
        # Split the variable on spaces into an array of paths.
        read -r -a extra <<< "${EXTRA_VIEW_FILES}"
        files+=("${extra[@]}")
    fi
    # Every list must exist: a typo must not silently grant less (or more).
    for file in "${files[@]}"; do
        [[ -f "${file}" ]] || die "view list not found: ${file}"
    done
    # Drop comments and whitespace, keep non-empty lines.
    while read -r name; do
        [[ -z "${name}" ]] && continue
        # Only plain dictionary object names: letters, digits, _ and $.
        [[ "${name}" =~ ^[A-Z][A-Z0-9_\$]{0,127}$ ]] || die "invalid view name in a view list: '${name}'"
        echo "${name}"
    # sort -u: a view listed in two files is granted once, in a fixed order.
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "${files[@]}" | sort -u)
}

# Run a statement file through SQLcl MCP as the agent, without a model.
# Usage: replay <file> [--json]
replay() {
    [[ -x "${HARNESS_PYTHON}" ]] || die "agent harness not set up. Run agent-harness/setup_harness.sh first."
    # Run from the harness folder so it finds its .env (SQLcl path, restrict level).
    (cd "${HARNESS_DIR}" && "${HARNESS_PYTHON}" replay_sql.py --connection "${MCP_CONNECTION}" --file "$@")
}
