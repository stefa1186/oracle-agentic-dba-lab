#!/usr/bin/env bash
# =============================================================================
# 02_build.sh
#
# Builds the database part of the lab, as the lab user:
#   1. a database password, generated once and stored as a Podman secret
#   2. the lab network and the datafile volume (created once)
#   3. Oracle AI Database 26ai Free in a rootless container, recreated from
#      the current settings, then a wait until FREEPDB1 is open
#
# Run as the lab user, after 00_root_setup.sh (root) and 01_prereqs.sh.
#
# Deterministic by design: every run produces the same result from the same
# settings. The container is recreated each time; only the datafiles
# (volume) and the password are kept.
# Oracle analogy: re-creating the instance from a fixed spfile on every
# start. The datafiles persist; the instance configuration never drifts.
#
# After a server reboot, run this script again to start the database.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read env.example and .env.
load_config
# Must be the lab user, in a proper login session.
require_lab_user

# The root setup must have been done: the outbound policy is part of the cage.
systemctl is-active --quiet "${EGRESS_UNIT}" || die "the outbound policy is not active. Run: sudo ./00_root_setup.sh"

# =============================================================================
step "1/3 Database password"
# =============================================================================
# Private folder for lab files, readable by the lab user only.
install -d -m 700 "${HOME}/.config" "${LAB_CONF_DIR}"

if [[ -f "${DB_PASSWORD_FILE}" ]]; then
    # Keep the existing password: the datafiles were created with it.
    info "Using the existing password in ${DB_PASSWORD_FILE}."
else
    # A missing password with existing datafiles means it is lost; a new one
    # would not match the database. Stop instead of guessing.
    if podman volume exists "${DB_VOLUME}"; then
        die "${DB_PASSWORD_FILE} is missing but the datafiles (${DB_VOLUME}) exist. Run ./99_destroy.sh --db-only, then rerun."
    fi
    # Create the file with mode 600 from the start (umask 077), then write a
    # random password: starts with a letter, contains upper case, lower case
    # and a digit (Oracle's rules). No trailing newline: the whole file is
    # the password.
    ( umask 077 && python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("Lab" + "".join(secrets.choice(a) for _ in range(20)) + "7", end="")' > "${DB_PASSWORD_FILE}" )
    info "Generated a new password in ${DB_PASSWORD_FILE}."
fi

# Store the password as a Podman secret. The container receives it as
# ORACLE_PWD at start, but it never appears in "podman inspect" output.
# --replace makes this step the same on every run.
podman secret create --replace "${DB_SECRET}" "${DB_PASSWORD_FILE}" >/dev/null
info "Podman secret '${DB_SECRET}' set."

# =============================================================================
step "2/3 Network and datafile volume"
# =============================================================================
# The lab's own network segment (created once).
if podman network exists "${DB_NETWORK}"; then
    info "Network ${DB_NETWORK} exists."
else
    podman network create "${DB_NETWORK}" >/dev/null
    info "Network ${DB_NETWORK} created."
fi
# The datafiles (created once; a rebuild never touches them).
if podman volume exists "${DB_VOLUME}"; then
    info "Volume ${DB_VOLUME} exists."
else
    podman volume create "${DB_VOLUME}" >/dev/null
    info "Volume ${DB_VOLUME} created."
fi

# =============================================================================
step "3/3 Database container"
# =============================================================================
# The image comes from root's setup: the lab user's HTTPS reaches only the
# allowed hosts (env.example), not the container registry.
podman image exists "${DB_IMAGE}" || die "the database image is missing. Root downloads it: sudo ./00_root_setup.sh"
# Show the image reference (pinned by digest in env.example) and its digest, for the run notes.
info "Image:  ${DB_IMAGE}"
info "Digest: $(podman image inspect --format '{{.Digest}}' "${DB_IMAGE}")"

# Recreate the container from the current settings. --replace stops and
# removes an existing container of the same name first; the datafiles on the
# volume are kept, so the database itself survives.
info "Creating container ${DB_CONTAINER}."
podman run \
    --detach \
    --replace \
    --name "${DB_CONTAINER}" \
    --network "${DB_NETWORK}" \
    --publish "127.0.0.1:${DB_PORT}:1521" \
    --volume "${DB_VOLUME}:/opt/oracle/oradata" \
    --secret "${DB_SECRET},type=env,target=ORACLE_PWD" \
    --security-opt no-new-privileges \
    --memory "${DB_MEMORY}" \
    --cpus "${DB_CPUS}" \
    --stop-timeout 120 \
    "${DB_IMAGE}" >/dev/null
# What each option does:
#   --detach              run in the background
#   --replace             recreate it if it already exists (deterministic rebuild)
#   --network             attach to the lab network only
#   --publish 127.0.0.1:  listener reachable from this server only, never 0.0.0.0
#   --volume              datafiles on the named volume
#   --secret ...type=env  password delivered as ORACLE_PWD, not stored in the config
#   --security-opt no-new-privileges  no privilege gain inside the container
#   --memory / --cpus     resource limits
#   --stop-timeout 120    time for a clean SHUTDOWN before the container is killed

# Wait until FREEPDB1 is open READ WRITE. The first build creates the
# database from scratch inside the container, which takes a while.
info "Waiting for FREEPDB1 to open (up to ${DB_READY_TIMEOUT}s; the first build takes longest)..."
deadline=$((SECONDS + DB_READY_TIMEOUT))
until [[ "$(pdb_open_mode)" == "READWRITE" ]]; do
    # The container must still be running.
    state="$(container_state)"
    if [[ "${state}" != "running" ]]; then
        podman logs --tail 30 "${DB_CONTAINER}" >&2 || true
        die "the database container is not running (state: ${state})."
    fi
    # Stop at the timeout.
    (( SECONDS < deadline )) || die "FREEPDB1 not open after ${DB_READY_TIMEOUT}s. Check the log: podman logs ${DB_CONTAINER}"
    # Progress dot, then check again in 15 seconds.
    printf '.'
    sleep 15
done
echo

# =============================================================================
step "Lab ready"
# =============================================================================
info "Database: Oracle AI Database 26ai Free, container ${DB_CONTAINER}"
info "Connect:  127.0.0.1:${DB_PORT}/FREEPDB1 (from this server only)"
info "Password: SYS / SYSTEM / PDBADMIN, in ${DB_PASSWORD_FILE}"
info "SQL*Plus: podman exec -it ${DB_CONTAINER} sqlplus / as sysdba"
info "Next:     ./03_verify.sh"
