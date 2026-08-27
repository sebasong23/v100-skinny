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
# Usage:
#   ./run.sh                  # binds 0.0.0.0:8000
#   PORT=8001 ./run.sh         # any serve-tp2-pcie.sh env var works here too
#   HOST=127.0.0.1 ./run.sh    # back to loopback-only if needed
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export HOST="${HOST:-0.0.0.0}"
exec bash serve-tp2-pcie.sh "$@"
