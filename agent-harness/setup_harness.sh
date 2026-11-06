#!/usr/bin/env bash
# =============================================================================
# setup_harness.sh
#
# Creates (or updates) the isolated Python virtual environment for the agent
# harness. Run it as the lab's dedicated Linux user, never as root.
#
# Oracle analogy: a virtual environment is to Python what a separate
# ORACLE_HOME is to Oracle: its own binaries and libraries, so nothing here
# touches the system Python, and deleting the folder removes it completely.
#
# Safe to run more than once: an existing environment is reused and its
# packages are brought up to date with requirements.txt.
# =============================================================================

# Stop on any error (-e), on use of an unset variable (-u), and on a failure
# anywhere in a pipeline (-o pipefail), so a half-finished setup never looks successful.
set -euo pipefail

# Absolute path of the folder containing this script, whatever the current directory is.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Location of the virtual environment, inside the harness folder (ignored by git).
VENV_DIR="${HARNESS_DIR}/.venv"

# Refuse to run as root: the harness belongs to the lab user, like Oracle belongs to the oracle user.
if [[ "${EUID}" -eq 0 ]]; then
    # Explain why and exit with an error code.
    echo "ERROR: run this as the lab user, not as root." >&2
    exit 1
fi

# Check that python3 exists before trying to use it.
if ! command -v python3 >/dev/null 2>&1; then
    # Python 3 is installed by the one root step, post 01's 00_root_setup.sh.
    echo "ERROR: python3 not found. Run post-01-why-and-the-cage/00_root_setup.sh (as root) first." >&2
    exit 1
fi

# The MCP client library needs Python 3.10 or newer; check the installed version.
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    # Report the version found and stop.
    echo "ERROR: Python 3.10+ required, found $(python3 --version)." >&2
    exit 1
fi

# Create the virtual environment only if it does not exist yet (idempotent).
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    # Build a fresh environment with its own pip.
    echo "Creating virtual environment in ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
else
    # Reuse the existing one.
    echo "Reusing virtual environment in ${VENV_DIR}"
fi

# Upgrade pip inside the environment, quietly.
"${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip
# Install or update the harness dependencies to the versions allowed by requirements.txt.
"${VENV_DIR}/bin/python" -m pip install --quiet --upgrade -r "${HARNESS_DIR}/requirements.txt"

# Create .env from the template only if it doesn't exist, so a rerun never overwrites your key.
if [[ ! -f "${HARNESS_DIR}/.env" ]]; then
    # Copy the template.
    cp "${HARNESS_DIR}/env.example" "${HARNESS_DIR}/.env"
    # Make it readable by the lab user only, like a wallet or a password file.
    chmod 600 "${HARNESS_DIR}/.env"
    # Remind the operator to fill it in.
    echo "Created ${HARNESS_DIR}/.env from env.example. Edit it and set OPENROUTER_API_KEY and DEFAULT_MODEL."
fi

# Make the scripts executable (harmless if they already are).
chmod +x "${HARNESS_DIR}/run_agent.py" "${HARNESS_DIR}/run_matrix.sh"

# Final confirmation with the installed versions, for the run notes.
echo "Harness ready:"
"${VENV_DIR}/bin/python" -m pip list 2>/dev/null | grep -Ei '^(mcp|openai|python-dotenv) '
