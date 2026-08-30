#!/usr/bin/env bash
# =============================================================================
# stress-test.sh — sustained-load thermal/stability test for the local
# vLLM server (default http://127.0.0.1:8000), for checking whether the
# cooling setup (e.g. a fan in low-noise mode) can hold up under continuous
# generation.
#
# Fires CONCURRENCY parallel streams of long-generation chat completions
# back-to-back for DURATION seconds, while sampling nvidia-smi every
# SAMPLE_INTERVAL seconds (temp / power / clocks / utilization) into a CSV.
# Prints a live temp/power line as it goes and a summary at the end.
#
# Usage:
#   ./scripts/stress-test.sh                      # 5 min, 4 concurrent streams
#   DURATION=1800 ./scripts/stress-test.sh         # 30 min soak
#   CONCURRENCY=8 ./scripts/stress-test.sh          # heavier load
#   PORT=8091 ./scripts/stress-test.sh              # different server port
#
# Stop early any time with Ctrl+C — cleans up background jobs and still
# prints the summary from whatever was sampled so far.
# =============================================================================
set -uo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
MODEL="${MODEL:-qwen3.8-27b}"
DURATION="${DURATION:-300}"        # seconds
CONCURRENCY="${CONCURRENCY:-4}"    # parallel request streams
MAX_TOKENS="${MAX_TOKENS:-1024}"   # generation length per request
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-2}"  # nvidia-smi sampling period, seconds

API="http://${HOST}:${PORT}/v1/chat/completions"
OUTDIR="${OUTDIR:-$(dirname "${BASH_SOURCE[0]}")/../results}"
mkdir -p "$OUTDIR"
TS="$(date +%Y%m%d-%H%M%S)"
GPULOG="${OUTDIR}/stress-gpu-${TS}.csv"
REQLOG="${OUTDIR}/stress-requests-${TS}.log"

echo "==> stress-test.sh"
echo "    API:          $API"
echo "    duration:     ${DURATION}s"
echo "    concurrency:  $CONCURRENCY"
echo "    max_tokens:   $MAX_TOKENS per request"
echo "    gpu log:      $GPULOG"
echo "    request log:  $REQLOG"
echo

# --- sanity check server is up before hammering it ---
if ! curl -sf -m 5 "http://${HOST}:${PORT}/v1/models" >/dev/null; then
  echo "stress-test.sh: server not reachable at http://${HOST}:${PORT}/v1/models" >&2
  exit 1
fi

PROMPT='Write a long, detailed, technical explanation (at least 500 words) of how transformer attention mechanisms work, including the math for scaled dot-product attention, multi-head attention, and why causal masking is needed for autoregressive decoding.'

PAYLOAD=$(python3 - "$MODEL" "$MAX_TOKENS" "$PROMPT" <<'EOF'
import json, sys
model, max_tokens, prompt = sys.argv[1], int(sys.argv[2]), sys.argv[3]
print(json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": max_tokens,
    "stream": False,
}))
EOF
)

STOP_FILE="$(mktemp -u)"  # reserve a path only — must NOT exist yet, workers poll for its creation
trap 'touch "$STOP_FILE"; wait 2>/dev/null; echo; echo "Interrupted — see summary below."; summarize' INT TERM

# --- GPU sampler: background loop, CSV output ---
nvidia-smi --query-gpu=timestamp,index,temperature.gpu,power.draw,clocks.current.sm,utilization.gpu \
  --format=csv,noheader -l "$SAMPLE_INTERVAL" > "$GPULOG" &
GPU_PID=$!

# --- live printer: tails the GPU log, prints one line per sample ---
( tail -n +1 -f "$GPULOG" 2>/dev/null | while read -r line; do
    echo "  $line"
  done ) &
TAIL_PID=$!

# --- load workers ---
worker() {
  local id=$1
  local n=0
  local end=$(( $(date +%s) + DURATION ))
  while [[ ! -f "$STOP_FILE" ]] && [[ $(date +%s) -lt $end ]]; do
    n=$((n + 1))
    t0=$(date +%s.%N)
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 120 \
      -X POST "$API" -H 'Content-Type: application/json' -d "$PAYLOAD")
    t1=$(date +%s.%N)
    dt=$(python3 -c "print(f'{$t1 - $t0:.2f}')")
    echo "worker=$id req=$n status=$code latency=${dt}s" >> "$REQLOG"
  done
}

for i in $(seq 1 "$CONCURRENCY"); do
  worker "$i" &
done
WORKER_PIDS=$(jobs -p | grep -v "$GPU_PID\|$TAIL_PID")

echo "Running for ${DURATION}s with $CONCURRENCY concurrent streams... (Ctrl+C to stop early)"
echo

summarize() {
  kill "$GPU_PID" "$TAIL_PID" 2>/dev/null
  wait "$GPU_PID" "$TAIL_PID" 2>/dev/null
  rm -f "$STOP_FILE"

  echo
  echo "==> Summary"
  if [[ -s "$GPULOG" ]]; then
    python3 - "$GPULOG" <<'EOF'
import csv, sys
rows = list(csv.reader(open(sys.argv[1])))
by_gpu = {}
for r in rows:
    if len(r) < 6:
        continue
    _, idx, temp, power, clk, util = [x.strip() for x in r[:6]]
    try:
        temp = float(temp.split()[0]); power = float(power.split()[0])
        util = float(util.split()[0].rstrip('%')) if '%' not in util else float(util.split()[0])
    except ValueError:
        continue
    by_gpu.setdefault(idx, {"temp": [], "power": [], "util": []})
    by_gpu[idx]["temp"].append(temp)
    by_gpu[idx]["power"].append(power)
    by_gpu[idx]["util"].append(util)
for idx, d in sorted(by_gpu.items()):
    if not d["temp"]:
        continue
    print(f"  GPU {idx}: temp max={max(d['temp']):.0f}C avg={sum(d['temp'])/len(d['temp']):.1f}C | "
          f"power max={max(d['power']):.0f}W avg={sum(d['power'])/len(d['power']):.1f}W | "
          f"util avg={sum(d['util'])/len(d['util']):.0f}%")
EOF
  else
    echo "  (no GPU samples captured)"
  fi

  if [[ -s "$REQLOG" ]]; then
    total=$(wc -l < "$REQLOG")
    errs=$(grep -cv 'status=200' "$REQLOG" || true)
    avg_lat=$(awk -F'latency=' '{gsub(/s$/,"",$2); sum+=$2; n++} END {if (n>0) printf "%.2f", sum/n}' "$REQLOG")
    echo "  Requests: $total total, $errs non-200, avg latency ${avg_lat}s"
  else
    echo "  (no requests logged)"
  fi
  echo
  echo "  Raw logs: $GPULOG"
  echo "            $REQLOG"
}

# wait for either the duration to pass or Ctrl+C
sleep "$DURATION"
touch "$STOP_FILE"
wait $WORKER_PIDS 2>/dev/null
summarize
