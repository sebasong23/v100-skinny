#!/usr/bin/env bash
# =============================================================================
# runweb.sh — serve the static webui/ over HTTP.
#
# The webui/ directory doesn't live in this repo; it defaults to the copy in
# the pcie-runbook checkout. Override WEBUI_DIR to point elsewhere.
#
# Usage:
#   ./runweb.sh                        # binds 0.0.0.0:8087 (LAN / Tailscale reachable)
#   PORT=8088 ./runweb.sh               # different port
#   HOST=127.0.0.1 ./runweb.sh          # loopback-only instead
#   WEBUI_DIR=/path/to/webui ./runweb.sh
#
# ⚠️ No auth in front of this — anything that can reach this box on its
# LAN or tailnet can browse the served files. Don't port-forward it to
# the internet without a reverse proxy + auth.
# =============================================================================
set -euo pipefail

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8087}"
WEBUI_DIR="${WEBUI_DIR:-/home/sebasong/v100-qwen38/pcie-runbook/repo/webui}"

if [[ ! -d "$WEBUI_DIR" ]]; then
  echo "runweb.sh: WEBUI_DIR not found: $WEBUI_DIR" >&2
  exit 1
fi

echo "Serving $WEBUI_DIR on http://${HOST}:${PORT}"
exec python3 -m http.server "$PORT" --bind "$HOST" --directory "$WEBUI_DIR"
