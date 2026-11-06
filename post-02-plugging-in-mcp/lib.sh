#!/usr/bin/env bash
# =============================================================================
# lib.sh (post 02): sourced by the post 02 scripts, not executed.
#
# Reuses post 01's helpers (logging, lab settings, "must be the lab user",
# SQL*Plus inside the database container) and adds the post 02 settings.
# Oracle analogy: one package calling another, instead of copying its code.
# =============================================================================

# Folder of the post 02 scripts.
POST02_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Post 01's helpers: step/info/warn/die, load_config, require_lab_user, db_sqlplus ...
# shellcheck source=../post-01-why-and-the-cage/lib.sh
source "${POST02_DIR}/../post-01-why-and-the-cage/lib.sh"

# Load post 01 settings (lab user, database), then post 02 settings.
load_post02_config() {
    # Lab and database settings from post 01.
    load_config
    # Post 02 defaults.
    # shellcheck source=env.example
    source "${POST02_DIR}/env.example"
    # Post 02 local overrides, if any.
    if [[ -f "${POST02_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST02_DIR}/.env"
    fi
    # The agent's user name: a plain Oracle identifier, so it is safe inside SQL.
    [[ "${AGENT_DB_USER}" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "AGENT_DB_USER must be an upper-case Oracle identifier."
    # The connection name: letters, digits, dash and underscore only.
    [[ "${MCP_CONNECTION}" =~ ^[A-Za-z0-9_-]+$ ]] || die "MCP_CONNECTION may contain only letters, digits, - and _."
    # Restrict level: a single digit 0-4.
    [[ "${SQLCL_RESTRICT}" =~ ^[0-4]$ ]] || die "SQLCL_RESTRICT must be 0-4."
    # The SQLcl launcher inside the install folder.
    SQLCL_BIN="${SQLCL_DIR}/bin/sql"
    # The agent's database password, generated once, readable by the lab user only.
    AGENT_PASSWORD_FILE="${LAB_CONF_DIR}/agent_pwd"
}

# Stop unless SQLcl is installed.
require_sqlcl() {
    [[ -x "${SQLCL_BIN}" ]] || die "SQLcl not installed. Run ./01_install_sqlcl.sh first."
}

# Stop unless the database is up (post 01's 02_build.sh).
require_database() {
    [[ "$(pdb_open_mode)" == "READWRITE" ]] || die "FREEPDB1 is not open. Run post-01-why-and-the-cage/02_build.sh first."
}
