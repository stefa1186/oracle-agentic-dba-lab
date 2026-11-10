#!/usr/bin/env bash
# =============================================================================
# 01_get_model.sh
#
# Downloads Oracle's prebuilt embedding model (all-MiniLM-L12-v2, augmented
# with its tokenizer, ONNX format) to MODEL_DIR on the server, and checks it:
#   - MODEL_SHA256 set (in .env): the zip must match it, or the script stops
#   - MODEL_SHA256 empty: the SHA-256 is printed, to be pinned in .env, so
#     every later download is verified (Oracle publishes no checksum)
# Then unpacks the ONNX file. Skips the download if a verified zip is there.
#
# Run as the lab user. Outbound HTTPS only (allowed by post 01's firewall).
# Writes only under MODEL_DIR.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-08 settings.
load_post08_config
# Must be the lab user.
require_lab_user

zip="${MODEL_DIR}/$(basename "${MODEL_URL}")"
mkdir -p "${MODEL_DIR}"

step "The model zip"
# Download only if there's no zip yet (rerunning never downloads twice).
if [[ ! -s "${zip}" ]]; then
    # The lab user reaches only the allowed hosts: a download needs root's window.
    "$(dirname "${BASH_SOURCE[0]}")/../post-01-why-and-the-cage/require_download_window.sh"
    info "Downloading ${MODEL_URL}"
    # Into a temporary name first: an interrupted download never looks complete.
    curl -fL --retry 3 --connect-timeout 30 -o "${zip}.part" "${MODEL_URL}"
    mv "${zip}.part" "${zip}"
else
    info "Already downloaded: ${zip}"
fi
sha="$(sha256sum "${zip}" | awk '{ print $1 }')"
info "SHA-256: ${sha}"
info "Size:    $(du -h "${zip}" | awk '{ print $1 }')"

step "Checksum"
if [[ -n "${MODEL_SHA256}" ]]; then
    # Pinned: it must match, or the file is not the one we tested with.
    [[ "${sha}" == "${MODEL_SHA256}" ]] || die "checksum mismatch: expected ${MODEL_SHA256}. Delete ${zip} and retry, or investigate."
    info "PASS: matches MODEL_SHA256."
else
    warn "MODEL_SHA256 is not pinned. To verify every later download, add this line to ${POST08_DIR}/.env:"
    info "MODEL_SHA256=${sha}"
fi

step "Unpacking ${MODEL_FILE}"
# Python's zipfile: no dependency on the unzip package. Only the ONNX file and the README.
python3 - "${zip}" "${MODEL_DIR}" "${MODEL_FILE}" <<'PY'
import sys, zipfile
zip_path, out_dir, onnx = sys.argv[1:4]
with zipfile.ZipFile(zip_path) as z:
    names = z.namelist()
    # The ONNX file must be in the zip, at its top level.
    if onnx not in names:
        sys.exit(f"ERROR: {onnx} not in the zip (it contains: {', '.join(names)})")
    for name in names:
        # Only plain top-level files: never a path that could escape out_dir.
        if "/" not in name and not name.startswith("."):
            z.extract(name, out_dir)
            print(f"    {name}")
PY
info "$(du -h "${MODEL_DIR}/${MODEL_FILE}" | awk '{ print $1 }')  ${MODEL_DIR}/${MODEL_FILE}"

step "Done"
info "Next: ./02_setup.sh"
