#!/usr/bin/env bash
# =============================================================================
# lib.sh: helpers shared by the post 01 scripts. It is sourced, not executed:
#   source "$(dirname "$0")/lib.sh"
#
# Oracle analogy: a shared PL/SQL package. Every script calls the same
# procedures, so settings, logging and checks are defined once.
# =============================================================================

# Folder that contains the post 01 scripts (and this file).
POST01_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Text written in the comment (GECOS) field of the lab user. The removal step
# only deletes a user carrying this marker, so it can never remove a real
# user by mistake.
LAB_MARKER="oracle-agentic-dba-lab lab user"

# Name of the nftables table holding the lab user's outbound policy.
EGRESS_TABLE="oralab_egress"
# File with the outbound policy rules (root-owned: the lab user can't change it).
EGRESS_NFT_FILE="/etc/oralab/egress.nft"
# systemd unit that loads the policy at every boot.
EGRESS_UNIT="oralab-egress.service"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

# Print a step heading.
step() { printf '\n==> %s\n' "$*"; }
# Print an informational line.
info() { printf '    %s\n' "$*"; }
# Print a warning to stderr.
warn() { printf '    WARNING: %s\n' "$*" >&2; }
# Print an error to stderr and stop with exit code 1.
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------

# Load env.example (defaults), then .env (local overrides) if it exists.
load_config() {
    # Defaults, always present in the repository.
    # shellcheck source=env.example
    source "${POST01_DIR}/env.example"
    # Local overrides, optional and never committed.
    if [[ -f "${POST01_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${POST01_DIR}/.env"
    fi
    # The lab user name must be a plain Linux user name, and never root.
    [[ "${LAB_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "LAB_USER '${LAB_USER}' is not a valid user name."
    [[ "${LAB_USER}" != "root" ]] || die "LAB_USER must not be root."
    # Derived values: home folder, private config folder, password file.
    LAB_HOME="/home/${LAB_USER}"
    LAB_CONF_DIR="${LAB_HOME}/.config/oralab"
    DB_PASSWORD_FILE="${LAB_CONF_DIR}/oracle_pwd"
}

# -----------------------------------------------------------------------------
# Who is running the script
# -----------------------------------------------------------------------------

# Stop unless running as root (only 00_root_setup.sh uses this).
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "run this script as root (sudo $0)."
}

# Stop unless running as the lab user (every other script uses this).
# Oracle analogy: Oracle's tools refuse to run as root; so do these.
require_lab_user() {
    [[ "${EUID}" -ne 0 ]] || die "do not run this as root. Log in as the lab user: sudo machinectl shell ${LAB_USER}@"
    [[ "$(id -un)" == "${LAB_USER}" ]] || die "run this as '${LAB_USER}' (current user: $(id -un)). Log in with: sudo machinectl shell ${LAB_USER}@"
    # Rootless Podman needs the user's runtime directory, /run/user/<uid>.
    # Linger (00_root_setup.sh) keeps it in place permanently, so set the
    # variables that point to it ourselves. The scripts then behave the same
    # however the shell was opened (machinectl shell, su -, ssh, ...).
    local runtime_dir="/run/user/$(id -u)"
    # The directory must exist; if not, linger is off (root setup not done).
    [[ -d "${runtime_dir}" ]] || die "${runtime_dir} does not exist: linger is not enabled. Run post-01-why-and-the-cage/00_root_setup.sh as root."
    # Where rootless Podman keeps its runtime state.
    export XDG_RUNTIME_DIR="${runtime_dir}"
    # The user's D-Bus socket, which Podman uses to talk to systemd.
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus"
}

# True if the lab user exists.
lab_user_exists() { id -u "${LAB_USER}" >/dev/null 2>&1; }

# True if the lab user carries the lab marker (i.e. 00_root_setup.sh created it).
lab_user_is_ours() {
    # Field 5 of the passwd entry is the comment.
    [[ "$(getent passwd "${LAB_USER}" | cut -d: -f5)" == "${LAB_MARKER}" ]]
}

# -----------------------------------------------------------------------------
# Database checks
# -----------------------------------------------------------------------------

# Run SQL*Plus as SYSDBA inside the container (OS authentication in the
# container, no password needed). The SQL comes from stdin.
db_sqlplus() {
    podman exec -i "${DB_CONTAINER}" sqlplus -s -L / as sysdba
}

# Print the open mode of FREEPDB1 without spaces ("READWRITE" when open),
# or nothing if the database isn't reachable yet.
pdb_open_mode() {
    db_sqlplus <<'SQL' 2>/dev/null | tr -d '[:space:]' || true
set heading off feedback off pagesize 0 verify off
select open_mode from v$pdbs where name = 'FREEPDB1';
exit
SQL
}

# Print the container state (running, exited, ...) or "missing".
container_state() {
    podman inspect --format '{{.State.Status}}' "${DB_CONTAINER}" 2>/dev/null || echo missing
}
