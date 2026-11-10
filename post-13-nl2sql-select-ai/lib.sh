#!/usr/bin/env bash
# =============================================================================
# lib.sh: helpers shared by the post 13 scripts. Sourced, not executed.
# Builds on post 02's helpers (post 01's settings, SQLcl's location).
# =============================================================================

# Folder of the post 13 scripts.
POST13_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Post 02's helpers, which load post 01's (settings, logging, db_sqlplus).
# shellcheck source=../post-02-plugging-in-mcp/lib.sh
source "${POST13_DIR}/../post-02-plugging-in-mcp/lib.sh"

# Read post 01, post 02 and post 13 settings, and derive the file names.
load_post13_config() {
    # Post 01 and post 02 settings (lab user, database, SQLcl).
    load_post02_config
    # Post 13 defaults, then local overrides.
    # shellcheck source=env.example
    source "${POST13_DIR}/env.example"
    if [[ -f "${POST13_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST13_DIR}/.env"
    fi
    # SH's private password file (mode 600), next to post 01's.
    SH_PASSWORD_FILE="${LAB_CONF_DIR}/sh_pwd"
    # Downloads and results of this post.
    DOWNLOAD_DIR="${HOME}/opt/downloads"
    OUT_DIR="${HOME}/oracle-agentic-dba-lab/output/post-13-nl2sql-select-ai"
}

# Create a password file once: a letter first, upper and lower case and a
# digit, letters and digits only (safe inside SQL quotes), mode 600.
ensure_password() {
    [[ -f "$1" ]] && return 0
    ( umask 077 && python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("Lab" + "".join(secrets.choice(a) for _ in range(20)) + "7", end="")' > "$1" )
}
