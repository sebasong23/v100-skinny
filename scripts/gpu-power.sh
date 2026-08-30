#!/usr/bin/env bash
# =============================================================================
# gpu-power.sh — manual idle-power toggle for both V100s.
#
# The driver keeps these GPUs pinned at P0 / ~1230MHz SM clock (~42-45W
# each) the whole time the vLLM server holds its CUDA context open, even
# at 0% utilization — it never reports itself as truly idle. Locking the
# SM clock ceiling low drops that to ~30W each; releasing the lock
# restores full boost clocks for serving.
#
# ⚠️ While locked down, generation will crawl (capped at 405MHz) — always
# run `up` before sending a real request, and give it a couple seconds to
# take effect.
#
# Usage:
#   ./scripts/gpu-power.sh down   # drop both GPUs to ~30W idle
#   ./scripts/gpu-power.sh up     # restore full clocks before serving
#   ./scripts/gpu-power.sh status # show current power/clock/pstate
# =============================================================================
set -euo pipefail

case "${1:-}" in
  down)
    sudo -n nvidia-smi -i 0,1 -lgc 135,405
    echo "==> GPUs 0,1 locked to low-power idle (~30W each). Run 'up' before serving."
    ;;
  up)
    sudo -n nvidia-smi -i 0,1 -rgc
    echo "==> GPUs 0,1 clock lock released — back to full boost for serving."
    ;;
  status)
    ;;
  *)
    echo "Usage: $0 {down|up|status}" >&2
    exit 1
    ;;
esac

nvidia-smi --query-gpu=index,power.draw,clocks.sm,pstate --format=csv
