#!/usr/bin/env bash
# =============================================================================
# 02_pull_model.sh
#
# Downloads one or more models into the local Ollama server's volume.
#
# Usage:
#   ./02_pull_model.sh <model> [<model> ...]
#   e.g. ./02_pull_model.sh qwen3:8b
#
# Pick models that support tool calling (the Ollama model library marks them
# with a "tools" tag), then confirm with 03_check_tool_calling.sh.
#
# Safe to run more than once: pulling a model that is already present only
# checks it is complete and up to date, like a second RMAN restore validate.
# This is the only step that needs internet access; serving models doesn't.
# =============================================================================

# Stop on errors, unset variables and pipeline failures.
set -euo pipefail

# Folder of this script, so it works from any current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load the shared settings (container name, port, ...).
# shellcheck source=ollama.conf
source "${SCRIPT_DIR}/ollama.conf"

# At least one model name is required.
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <model> [<model> ...]" >&2
    exit 1
fi

# The server must be running; point to the start script if it isn't.
if [[ "$(podman inspect --format '{{.State.Status}}' "${OLLAMA_CONTAINER}" 2>/dev/null)" != "running" ]]; then
    echo "ERROR: container ${OLLAMA_CONTAINER} is not running. Run ./01_start_ollama.sh first." >&2
    exit 1
fi

# The lab user reaches only the allowed hosts: model downloads need root's window.
"${SCRIPT_DIR}/../../post-01-why-and-the-cage/require_download_window.sh"
# Pull every model given on the command line.
for model in "$@"; do
    # Show which model is being pulled.
    echo "Pulling ${model}"
    # Run the pull inside the container; the files land in the models volume.
    podman exec "${OLLAMA_CONTAINER}" ollama pull "${model}"
done

# Show every model now available, with its size, for the run notes.
echo
echo "Models available locally:"
podman exec "${OLLAMA_CONTAINER}" ollama list
