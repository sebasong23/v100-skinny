#!/usr/bin/env bash
# =============================================================================
# serve-tp2-pcie.sh — Qwen3.8-27B NVFP4 on PCIe V100 (TP2 or single-card TP1)
# Same config as v100-skinny's serve-qwen38-native.sh plus the three PCIe
# fixes from README.md. TP=1 needs no NCCL at all. Loopback only: NO auth.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKPT="${CKPT:-$(dirname "$REPO_ROOT")/RadixArk_Qwen3.8-27B-NVFP4}"
[ -f "$CKPT/config.json" ] || { echo "ERROR: checkpoint not found at $CKPT" >&2; exit 2; }

PY="$REPO_ROOT/.venv-sm70/bin/python"
[ -x "$PY" ] || { echo "ERROR: run setup.sh first" >&2; exit 2; }

TP="${TP:-2}"; K="${K:-7}"; K1=$((K + 1)); K2=$((K1 * 2))

# TP2 PCIe setup: the symmetric stack targets 2x V100 (SM70). No NVLink / P2P —
# these cards talk over PCIe SHM. Fail loudly if the second GPU isn't attached
# (boots as TP=1 die with a prepack OOM ~31 GiB on one 32 GiB card).
NGPU=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
if [ "$TP" = "2" ] && [ "$NGPU" -lt 2 ]; then
  echo "ERROR: TP=2 needs two V100s; only $NGPU GPU(s) visible." >&2
  echo "       Existing single-V100 stack OOMs at weight prepack (~31 GiB)." >&2
  exit 3
fi
GMU="${GMU:-0.9}"; MML="${MML:-131072}"; MNS="${MNS:-1}"; MBT="${MBT:-4096}"
PORT="${PORT:-8000}"; HOST="${HOST:-127.0.0.1}"
THINKING="${THINKING:-true}"; EFFORT="${EFFORT:-medium}"; DRAFT="${DRAFT:-probabilistic}"
# EAGER=1: bypass torch.compile + CUDA-graph capture entirely (diagnostic —
# isolates whether a hang/livelock is compile/graph-capture-specific).
EAGER="${EAGER:-0}"; EAGER_FLAG=""
[ "$EAGER" = "1" ] && EAGER_FLAG="--enforce-eager"
# NOPREFIXCACHE=1: pass --no-enable-prefix-caching (diagnostic / low-VRAM —
# disables automatic prefix-cache reuse across requests).
NOPREFIXCACHE="${NOPREFIXCACHE:-0}"; PREFIXCACHE_FLAG=""
[ "$NOPREFIXCACHE" = "1" ] && PREFIXCACHE_FLAG="--no-enable-prefix-caching"
# NOSPEC=1: drop --speculative-config (MTP draft model) entirely (diagnostic —
# isolates whether a hang is specific to MTP speculative decoding vs. the
# base GDN-linear-attention model on TP2).
NOSPEC="${NOSPEC:-0}"; SPEC_FLAG=""; SPEC_JSON=""
MTP_DEFAULTS=1
if [ "$NOSPEC" != "1" ]; then
  SPEC_FLAG="--speculative-config"
  SPEC_JSON="{\"method\":\"mtp\",\"num_speculative_tokens\":$K,\"draft_sample_method\":\"$DRAFT\",\"use_local_argmax_reduction\":true}"
else
  # VLLM_1CAT_ENABLE_SM70_MTP_DEFAULTS auto-applies MTP even with no
  # --speculative-config flag — must unset it too, or NOSPEC=1 is a no-op.
  MTP_DEFAULTS=0
fi
# TP=1 (single card): one GPU is enough; NCCL env below is harmless but unneeded
if [ -z "${CUDA_VISIBLE_DEVICES:-}" ]; then
  [ "$TP" = "1" ] && GPUS="0" || GPUS="0,1"
else
  GPUS="$CUDA_VISIBLE_DEVICES"
fi
LOG="${LOG:-$REPO_ROOT/serve-tp2.log}"

# PCIe FIX #1: torch JIT needs the ninja BINARY on PATH
export PATH="$REPO_ROOT/.venv-sm70/bin:$PATH"

# GPU occupancy guard (tolerates display daemons like NoMachine ~450 MiB)
USED=$(nvidia-smi -i "$GPUS" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1)
if [ "${USED:-0}" -ge 2000 ]; then
  echo "ABORT: GPUs $GPUS busy (${USED} MiB). Stop the other inference first." >&2
  nvidia-smi -i "$GPUS" --query-compute-apps=pid,used_memory --format=csv >&2
  exit 1
fi

echo "==> $CKPT | TP=$TP k=$K GMU=$GMU MML=$MML | $HOST:$PORT | log: $LOG"

exec env \
  CUDA_VISIBLE_DEVICES="$GPUS" \
  CUDA_DEVICE_ORDER=PCI_BUS_ID \
  CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-12.8}" \
  TORCH_CUDA_ARCH_LIST=7.0 \
  NCCL_P2P_DISABLE=1 \
  NCCL_IB_DISABLE=1 \
  VLLM_SM70_NVFP4_TURBOMIND=0 \
  VLLM_SM70_QUANT_BACKEND=marlin \
  VLLM_SM70_GEMMA_LONG_PREFILL_FUSED=0 \
  VLLM_1CAT_ENABLE_SM70_MTP_DEFAULTS="$MTP_DEFAULTS" \
  VLLM_SKINNY_NVFP4=1 \
  VLLM_SKINNY_QPN=1 \
  VLLM_SKINNY_QPN2=1 \
  VLLM_SKINNY_LMHEAD=1 \
  VLLM_SKINNY_LMHEAD_NATIVE=1 \
  VLLM_SKINNY_NVFP4_SRC="$REPO_ROOT/kernels/skinny_kernels.cu" \
  VLLM_SM70_MTP_DYNAMIC_DRAFT_VOCAB_DEFAULT=0 \
  VLLM_SM70_GDN_CHAIN_SPEC_FAST_BUILD=1 \
  VLLM_SM70_QPN8_MT2=1 \
  VLLM_FLASH_V100_DECODE_PARTITION_SIZE="${DECODE_PARTITION:-256}" \
  numactl --cpunodebind=0 --membind=0 \
  "$PY" -m vllm.entrypoints.openai.api_server \
  --model "$CKPT" \
  --served-model-name qwen3.8-27b \
  --trust-remote-code \
  --dtype float16 \
  --attention-backend FLASH_ATTN_V100 \
  --tensor-parallel-size "$TP" \
  --disable-custom-all-reduce \
  --kv-cache-dtype fp8_e5m2 \
  --gpu-memory-utilization "$GMU" \
  --max-model-len "$MML" \
  --max-num-seqs "$MNS" \
  --max-num-batched-tokens "$MBT" \
  --limit-mm-per-prompt '{"image":0,"video":0}' \
  --default-chat-template-kwargs "{\"enable_thinking\":$THINKING,\"reasoning_effort\":\"$EFFORT\"}" \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --compilation-config "{\"cudagraph_capture_sizes\":[$K1,$K2]}" \
  $SPEC_FLAG $SPEC_JSON \
  $EAGER_FLAG \
  $PREFIXCACHE_FLAG \
  --host "$HOST" --port "$PORT" 2>&1 | tee -a "$LOG"
