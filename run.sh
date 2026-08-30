#!/usr/bin/env bash
# =============================================================================
# run.sh — convenience entrypoint for the dual-V100 TP2 NVFP4 server.
# Thin wrapper over serve-tp2-pcie.sh: same env overrides all still work
# (TP, K, GMU, MML, PORT, EAGER, NOSPEC, ...), this just defaults HOST to
# 0.0.0.0 so the server is reachable from the LAN / Tailscale, not just
# loopback.
#
# ⚠️ Still NO AUTH on the server. Anything that can reach this box on its
# LAN or tailnet can hit the API. Don't expose this port further (no
# internet-facing port-forward) without putting a reverse proxy + auth
# in front of it.
#
# Also caps both GPUs' power limit (default 200W, down from the 250W
# default) before launching, to keep thermals/noise in check. Override with
# POWER_LIMIT_W, or set it to 0 to skip capping entirely.
#
# Usage:
#   ./run.sh                     # binds 0.0.0.0:8000, caps GPUs at 200W
#   PORT=8001 ./run.sh            # any serve-tp2-pcie.sh env var works here too
#   HOST=127.0.0.1 ./run.sh       # back to loopback-only if needed
#   POWER_LIMIT_W=250 ./run.sh    # back to stock power limit
#   POWER_LIMIT_W=0 ./run.sh      # skip the power-limit step entirely
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export HOST="${HOST:-0.0.0.0}"

POWER_LIMIT_W="${POWER_LIMIT_W:-200}"
if [[ "$POWER_LIMIT_W" != "0" ]]; then
  if sudo -n nvidia-smi -i 0,1 -pl "$POWER_LIMIT_W" >/dev/null 2>&1; then
    echo "==> capped GPU 0,1 power limit to ${POWER_LIMIT_W}W"
  else
    echo "==> warning: could not set GPU power limit to ${POWER_LIMIT_W}W (needs passwordless sudo for nvidia-smi); continuing at stock limit" >&2
  fi
fi

exec bash serve-tp2-pcie.sh "$@"
