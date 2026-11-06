#!/usr/bin/env bash
# =============================================================================
# 01_check_hardware.sh
#
# Can this server run the local models at all? A model runs where its file
# fits in memory, so this is a sizing check, like checking memory before you
# size an SGA:
#   1. CPU: model, cores, and the vector instructions (AVX2, AVX-512) that
#      the model runtime uses to compute fast on a CPU
#   2. GPU: is there an NVIDIA GPU? (This lab runs on the CPU either way.)
#   3. memory: total, and available right now (the database is running)
#   4. disk: free space where Podman keeps images and volumes
#   5. each model in LOCAL_MODELS: does it fit? It needs about its file size
#      (model_pins.txt) x RAM_FACTOR_PERCENT, plus 1 GiB
# Stops if a model doesn't fit, and says how to leave it out.
#
# Run as the lab user. Read-only: changes nothing.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-12 settings.
load_post12_config
# Must be the lab user.
require_lab_user

step "1/5 CPU"
# The CPU model, from the first processor entry.
info "Model:   $(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
# Threads the system can schedule (cores x threads per core).
info "Threads: $(nproc)"
# The vector instruction sets, from the CPU flags: the runtime picks the
# fastest code path this CPU supports.
flags="$(awk -F': ' '/^flags/ { print $2; exit }' /proc/cpuinfo)"
for f in avx2 avx512f; do
    # Padded to the width of "Threads:", so the values line up.
    if grep -qw "${f}" <<< "${flags}"; then info "$(printf '%-8s %s' "${f}:" yes)"; else info "$(printf '%-8s %s' "${f}:" no)"; fi
done

step "2/5 GPU"
# An NVIDIA GPU shows up as /dev/nvidia0 once its driver is loaded.
if [[ -e /dev/nvidia0 ]]; then
    info "NVIDIA device found (/dev/nvidia0). This lab still runs on the CPU (OLLAMA_GPU=0 in ollama.conf)."
else
    info "No NVIDIA GPU: the models run on the CPU."
fi

step "3/5 Memory"
# Total and available memory, from /proc/meminfo (values in kB). "Available"
# is what new processes can use without swapping, with the database running.
mem_total_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
mem_avail_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
info "Total:     $(( mem_total_kb / 1024 / 1024 )) GiB"
info "Available: $(( mem_avail_kb / 1024 / 1024 )) GiB (now, with the database running)"

step "4/5 Disk"
# Where rootless Podman keeps images and volumes (the models go into a volume).
store="$(podman info --format '{{ .Store.GraphRoot }}')"
# Free space there, in GiB.
free_gib="$(df -BG --output=avail "${store}" | tail -1 | tr -dc '0-9')"
info "Podman storage: ${store}"
info "Free:           ${free_gib} GiB"

step "5/5 The local models"
printf '    %-32s %9s %11s %11s  %s\n' "MODEL" "FILE" "RAM NEEDED" "DISK NEEDED" "VERDICT"
fail=0
# Disk still needed: models already in the Ollama volume need no more space.
for tag in ${LOCAL_MODELS}; do
    bytes="$(pin_bytes "${tag}")"
    # File size in GiB, rounded up.
    file_gib=$(( (bytes + 1073741823) / 1073741824 ))
    # RAM needed: file size x factor, plus 1 GiB, rounded up.
    need_gib=$(( (bytes * RAM_FACTOR_PERCENT / 100 + 1073741823) / 1073741824 + 1 ))
    # Disk needed: nothing if Ollama already has this exact model.
    if [[ "$(local_digest "${tag}")" == "sha256:$(pin_digest "${tag}")" || "$(local_digest "${tag}")" == "$(pin_digest "${tag}")" ]]; then
        disk_gib=0
    else
        disk_gib="${file_gib}"
    fi
    # The verdict: fits in available memory, and on the disk.
    if (( need_gib * 1024 * 1024 > mem_avail_kb )); then
        verdict="DOES NOT FIT in memory"
        fail=1
    elif (( disk_gib > free_gib )); then
        verdict="NOT ENOUGH DISK"
        fail=1
    else
        verdict="fits"
    fi
    printf '    %-32s %6s GiB %7s GiB %7s GiB  %s\n' "${tag}" "${file_gib}" "${need_gib}" "${disk_gib}" "${verdict}"
done

if (( fail )); then
    die "not every model fits. List only the ones that do in ${POST12_DIR}/.env, e.g.:
    LOCAL_MODELS=\"$(awk '{ print $1 }' <<< "${LOCAL_MODELS}")\""
fi

step "Done"
info "Every model fits. Next: ./02_prepare_online.sh"
