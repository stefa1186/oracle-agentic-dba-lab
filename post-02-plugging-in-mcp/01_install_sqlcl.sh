#!/usr/bin/env bash
# =============================================================================
# 01_install_sqlcl.sh
#
# Installs SQLcl (which contains Oracle's MCP server) in the lab user's home:
#   ~/opt/sqlcl            the program
#   ~/.local/bin/sql       a link, so "sql" is on the PATH (the harness uses it)
#   ~/.cache/oralab/       the downloaded zip, kept so reinstalls are identical
#
# Run as the lab user. Nothing is installed system-wide.
#
# Deterministic: the zip is downloaded once and verified against SQLCL_SHA256.
# On the very first install SQLCL_SHA256 is empty: the script prints the
# checksum and the version so you can pin them (env.example), like pinning
# the database image. Every later run installs exactly the same file.
# Oracle analogy: installing from a staged, checksummed software image
# instead of "whatever is on the download page today".
#
# Safe to rerun: it always reinstalls from the cached zip, giving the same result.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01 and post 02 settings.
load_post02_config
# Must be the lab user, in a proper login session.
require_lab_user

# Where the downloaded zip is kept.
CACHE_DIR="${HOME}/.cache/oralab"
ZIP_FILE="${CACHE_DIR}/sqlcl.zip"

step "1/4 Java"
# SQLcl needs Java 17 or 21 (installed by 00_root_setup.sh).
command -v java >/dev/null 2>&1 || die "java not found. Rerun post-01-why-and-the-cage/00_root_setup.sh as root (it installs Java 21)."
# Read the major version from "java -version" (printed on stderr), e.g. 21.
# Only the first line contains the quoted version, e.g. openjdk version "21.0.5".
java_major="$(java -version 2>&1 | awk -F'"' '/version "/ {split($2, v, "."); print v[1]}')"
# It must be a number before it can be compared.
[[ "${java_major}" =~ ^[0-9]+$ ]] || die "could not read the Java version."
info "Java ${java_major}"
(( java_major >= 17 )) || die "SQLcl needs Java 17 or newer; found ${java_major}."

step "2/4 Download"
# Create the cache folder (private to the lab user).
install -d -m 700 "${CACHE_DIR}"
if [[ -f "${ZIP_FILE}" ]]; then
    # Reuse the cached zip: same file, same install.
    info "Using cached ${ZIP_FILE}."
else
    # Download to a temporary name and rename only when complete, so an
    # interrupted download never looks like a finished one.
    info "Downloading ${SQLCL_URL}"
    curl -fL --retry 3 --output "${ZIP_FILE}.part" "${SQLCL_URL}"
    mv "${ZIP_FILE}.part" "${ZIP_FILE}"
fi

step "3/4 Checksum"
# SHA-256 of the zip.
actual_sha="$(sha256sum "${ZIP_FILE}" | awk '{print $1}')"
info "SHA-256: ${actual_sha}"
if [[ -n "${SQLCL_SHA256}" ]]; then
    # Pinned: only that exact file is acceptable.
    if [[ "${actual_sha}" != "${SQLCL_SHA256}" ]]; then
        die "checksum mismatch. Expected ${SQLCL_SHA256}. If you meant to upgrade, delete ${ZIP_FILE}, clear SQLCL_SHA256, rerun, then pin the new value."
    fi
    info "Matches the pinned SQLCL_SHA256."
else
    # Not pinned yet: carry on, and tell the operator what to pin.
    warn "SQLCL_SHA256 is not pinned. To make installs repeatable, set in env.example:"
    warn "  SQLCL_SHA256=${actual_sha}"
fi

step "4/4 Install"
# Unpack into a temporary folder next to the target, then swap it in, so a
# failed unpack never leaves a half-installed SQLcl.
install -d -m 755 "$(dirname "${SQLCL_DIR}")"
tmp_dir="$(mktemp -d "$(dirname "${SQLCL_DIR}")/.sqlcl-install.XXXXXX")"
unzip -q "${ZIP_FILE}" -d "${tmp_dir}"
# The zip contains a single top-level "sqlcl" folder.
[[ -x "${tmp_dir}/sqlcl/bin/sql" ]] || { rm -rf "${tmp_dir}"; die "unexpected zip layout: no sqlcl/bin/sql inside."; }
# Replace any previous install with the freshly unpacked one.
rm -rf "${SQLCL_DIR}"
mv "${tmp_dir}/sqlcl" "${SQLCL_DIR}"
rmdir "${tmp_dir}"
# Put "sql" on the lab user's PATH (~/.local/bin is on the PATH by default on EL).
install -d -m 755 "${HOME}/.local/bin"
ln -sfn "${SQLCL_BIN}" "${HOME}/.local/bin/sql"
info "Installed in ${SQLCL_DIR}; linked as ~/.local/bin/sql"

# Print the version banner, for the run notes.
info "$("${SQLCL_BIN}" -V 2>&1 | head -1)"

step "Done"
info "Next: ./02_create_agent_user.sh"
