#!/usr/bin/env bash
# =============================================================================
# 01_start_ollama.sh
#
# Starts a local model server (Ollama) in a rootless Podman container, owned
# by the lab user, with its API published on 127.0.0.1 only.
#
# Why local models: with a local model, everything the agent reads from the
# database stays on this server. Nothing is sent to an external provider.
# Oracle analogy: on-premises vs. cloud. Same client, same API, but the data
# never leaves your data centre.
#
# Oracle analogy for the pieces:
#   container = the instance (start it, stop it, throw it away)
#   volume    = the datafiles (the downloaded models survive the container)
#
# Safe to run more than once:
#   - container missing                  -> created and started
#   - settings changed in ollama.conf    -> recreated (models are kept)
#   - container stopped                  -> started
#   - container running                  -> left alone
# =============================================================================

# Stop on errors, unset variables and pipeline failures.
set -euo pipefail

# Folder of this script, so it works from any current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load the shared settings (image, names, port, limits).
# shellcheck source=ollama.conf
source "${SCRIPT_DIR}/ollama.conf"

# Rootless only: refuse root, as Oracle refuses to run its binaries as root.
if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: run this as the lab user, not as root (rootless Podman)." >&2
    exit 1
fi

# Podman and curl are installed by the one root step, post 01's 00_root_setup.sh.
command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not found. Run post-01-why-and-the-cage/00_root_setup.sh (as root) first." >&2; exit 1; }
# curl is used to wait for the API to come up.
command -v curl   >/dev/null 2>&1 || { echo "ERROR: curl not found. Run post-01-why-and-the-cage/00_root_setup.sh (as root) first." >&2; exit 1; }

# A fingerprint of every setting that is fixed when the container is created.
# It is stored as a label on the container; if ollama.conf changes, the
# fingerprint no longer matches and the container is recreated, so the running
# server always matches the file. Oracle analogy: an spfile change that needs
# a restart, done for you.
config="image=${OLLAMA_IMAGE} ctx=${OLLAMA_CONTEXT_LENGTH} parallel=${OLLAMA_NUM_PARALLEL} loaded=${OLLAMA_MAX_LOADED_MODELS} memory=${OLLAMA_MEMORY} gpu=${OLLAMA_GPU} port=${OLLAMA_PORT} volume=${OLLAMA_VOLUME}"
fingerprint="$(printf '%s' "${config}" | sha256sum | cut -c1-16)"

# An existing container with other settings is removed first (the models
# volume is not touched).
if podman container exists "${OLLAMA_CONTAINER}"; then
    current="$(podman inspect --format '{{ index .Config.Labels "lab.ollama.config" }}' "${OLLAMA_CONTAINER}")"
    if [[ "${current}" != "${fingerprint}" ]]; then
        echo "Settings changed (container ${current:-<none>}, ollama.conf ${fingerprint}): recreating ${OLLAMA_CONTAINER}."
        podman rm --force "${OLLAMA_CONTAINER}" >/dev/null
    fi
fi

# Does the container already exist? (podman container exists returns 0 if yes.)
if podman container exists "${OLLAMA_CONTAINER}"; then
    # Read its state: "running", "exited", "created", ...
    state="$(podman inspect --format '{{.State.Status}}' "${OLLAMA_CONTAINER}")"
    if [[ "${state}" == "running" ]]; then
        # Nothing to do; say so and continue to the readiness check.
        echo "Container ${OLLAMA_CONTAINER} is already running."
    else
        # Start the existing container with its original settings.
        echo "Starting existing container ${OLLAMA_CONTAINER} (state: ${state})."
        podman start "${OLLAMA_CONTAINER}" >/dev/null
    fi
else
    # Build the podman run options in an array, so optional ones can be added cleanly.
    opts=(
        # Run in the background.
        --detach
        # Fixed name, so the other scripts can find it.
        --name "${OLLAMA_CONTAINER}"
        # Publish the API on localhost only: not reachable from the network.
        --publish "127.0.0.1:${OLLAMA_PORT}:11434"
        # Store models in a named volume, created automatically if missing.
        --volume "${OLLAMA_VOLUME}:/root/.ollama"
        # Default context window for every model the server loads.
        --env "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
        # One request at a time per model, one model in memory at a time.
        --env "OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
        --env "OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
        # The settings fingerprint, so a later run can tell if ollama.conf changed.
        --label "lab.ollama.config=${fingerprint}"
        # Processes in the container can't gain new privileges (e.g. via setuid binaries).
        --security-opt no-new-privileges
    )
    # Optional memory cap.
    if [[ -n "${OLLAMA_MEMORY}" ]]; then
        opts+=(--memory "${OLLAMA_MEMORY}")
    fi
    # Optional NVIDIA GPU access through CDI.
    if [[ "${OLLAMA_GPU}" == "1" ]]; then
        opts+=(--device nvidia.com/gpu=all)
    fi
    # Without the image, podman downloads it: that needs root's download window.
    podman image exists "${OLLAMA_IMAGE}" || "${SCRIPT_DIR}/../../post-01-why-and-the-cage/require_download_window.sh"
    # Create and start the container.
    echo "Creating container ${OLLAMA_CONTAINER} from ${OLLAMA_IMAGE}."
    podman run "${opts[@]}" "${OLLAMA_IMAGE}" >/dev/null
fi

# Wait up to 60 seconds for the API to answer, like waiting for the listener
# to register the service before connecting.
echo -n "Waiting for the API on 127.0.0.1:${OLLAMA_PORT} "
for _ in $(seq 1 60); do
    # /api/version answers as soon as the server is ready.
    if curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
        echo "ready."
        break
    fi
    # Not ready yet: show progress and wait one second.
    echo -n "."
    sleep 1
done
# If it never answered, show the container log to explain why, and fail.
if ! curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
    echo " not ready after 60s. Last log lines:" >&2
    podman logs --tail 20 "${OLLAMA_CONTAINER}" >&2
    exit 1
fi

# Print the server version, the image and the settings, so every run can be
# traced to exactly this server (both are pinned in ollama.conf).
echo "Ollama version: $(curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/api/version")"
echo "Image:          ${OLLAMA_IMAGE}"
echo "Settings:       ${config}"
# Remind the operator of the matching harness setting.
echo "Harness setting: LOCAL_BASE_URL=http://127.0.0.1:${OLLAMA_PORT}/v1"
