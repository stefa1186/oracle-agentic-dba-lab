#!/usr/bin/env bash
# =============================================================================
# 99_remove_ollama.sh
#
# Stops and removes the local model server container.
#
# Usage:
#   ./99_remove_ollama.sh           remove the container, keep downloaded models
#   ./99_remove_ollama.sh --purge   also delete the models volume
#
# Oracle analogy: without --purge it's like dropping the instance but keeping
# the datafiles; --purge is DROP DATABASE INCLUDING DATAFILES.
#
# Safe to run more than once: anything already gone is skipped.
# =============================================================================

# Stop on errors, unset variables and pipeline failures.
set -euo pipefail

# Folder of this script, so it works from any current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load the shared settings (container and volume names).
# shellcheck source=ollama.conf
source "${SCRIPT_DIR}/ollama.conf"

# Read the optional --purge flag; reject anything else.
PURGE=0
case "${1:-}" in
    "")       ;;
    --purge)  PURGE=1 ;;
    *)        echo "Usage: $0 [--purge]" >&2; exit 1 ;;
esac

# Remove the container if it exists; --force stops it first if running.
if podman container exists "${OLLAMA_CONTAINER}"; then
    podman rm --force "${OLLAMA_CONTAINER}" >/dev/null
    echo "Removed container ${OLLAMA_CONTAINER}."
else
    echo "Container ${OLLAMA_CONTAINER} not present; nothing to remove."
fi

# With --purge, delete the models volume too.
if [[ "${PURGE}" -eq 1 ]]; then
    if podman volume exists "${OLLAMA_VOLUME}"; then
        podman volume rm "${OLLAMA_VOLUME}" >/dev/null
        echo "Removed volume ${OLLAMA_VOLUME} (downloaded models deleted)."
    else
        echo "Volume ${OLLAMA_VOLUME} not present; nothing to purge."
    fi
else
    # Without --purge, say where the models still are.
    echo "Kept volume ${OLLAMA_VOLUME}. Use --purge to delete downloaded models."
fi
