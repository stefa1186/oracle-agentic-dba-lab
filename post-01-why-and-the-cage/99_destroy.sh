#!/usr/bin/env bash
# =============================================================================
# 99_destroy.sh
#
# Removes what 02_build.sh created, as the lab user. Two levels:
#
#   ./99_destroy.sh --db-only
#       Removes the database container and its datafiles. Keeps the password
#       and the image. Then ./02_build.sh creates a brand-new database in
#       minutes.
#       Oracle analogy: DROP DATABASE, then DBCA from the same template.
#
#   ./99_destroy.sh --all
#       Removes everything 02_build.sh created: container, datafiles, image,
#       network, secret and password file. The lab user and the root setup
#       stay; remove those with "sudo ./00_root_setup.sh --remove".
#
# Asks for confirmation unless --yes is added.
# Safe to run more than once: anything already gone is skipped.
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

# Usage text, shown on wrong arguments.
usage() { echo "Usage: $0 --db-only|--all [--yes]" >&2; exit 1; }

# Parse the arguments: exactly one level, optionally --yes.
level=""
assume_yes=0
for arg in "$@"; do
    case "${arg}" in
        --db-only) level="db" ;;
        --all)     level="all" ;;
        --yes)     assume_yes=1 ;;
        *)         usage ;;
    esac
done
# A level is mandatory: no default for a destructive script.
[[ -n "${level}" ]] || usage

# Ask for confirmation: the user must type "destroy".
if (( ! assume_yes )); then
    if [[ "${level}" == "db" ]]; then
        echo "This deletes the database container and ALL its datafiles (volume ${DB_VOLUME})."
    else
        echo "This deletes the database, its datafiles, the image, the network, the secret and the password file."
    fi
    read -r -p "Type 'destroy' to confirm: " answer
    [[ "${answer}" == "destroy" ]] || die "not confirmed; nothing was changed."
fi

step "Removing the database"
# Stop (clean shutdown within the stop timeout) and remove the container.
# --ignore: no error if it doesn't exist.
podman rm --force --ignore "${DB_CONTAINER}" >/dev/null
info "Container ${DB_CONTAINER} removed."
# Remove the datafiles volume, if present.
if podman volume exists "${DB_VOLUME}"; then
    podman volume rm "${DB_VOLUME}" >/dev/null
    info "Volume ${DB_VOLUME} removed (datafiles deleted)."
fi

# --db-only stops here.
if [[ "${level}" == "db" ]]; then
    step "Done"
    info "Run ./02_build.sh to create a fresh database (same password, image already present)."
    exit 0
fi

step "Removing the image, network, secret and password"
# The image (several GB).
podman rmi --ignore "${DB_IMAGE}" >/dev/null && info "Image ${DB_IMAGE} removed."
# The lab network.
if podman network exists "${DB_NETWORK}"; then
    podman network rm "${DB_NETWORK}" >/dev/null
    info "Network ${DB_NETWORK} removed."
fi
# The password secret.
if podman secret exists "${DB_SECRET}"; then
    podman secret rm "${DB_SECRET}" >/dev/null
    info "Secret ${DB_SECRET} removed."
fi
# The password file.
rm -f "${DB_PASSWORD_FILE}"
info "Password file removed."

step "Done"
info "Rebuild with ./02_build.sh. To remove the lab user and the root setup too:"
info "  sudo ./00_root_setup.sh --remove   (from an administrator account)"
