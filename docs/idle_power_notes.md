# Dual-V100 idle power — VERDICT: driver keeps P0 while the server context is alive (2026-08-30)

Idle draw with the TP2 vLLM server up (model loaded, 0 requests in flight)
sat at **~42-45W/GPU** instead of a true idle floor. Confirmed cause: the
NVIDIA driver's own idle-detection never fires while vLLM holds its CUDA
context open (NCCL communicators + captured CUDA graphs for TP=2) — it has
nothing to do with the webui, browser tab, or the `-pl` power cap.

## Measured (Tesla V100-PCIE-32GB ×2, `nvidia-smi`)

| State | GPU0 | GPU1 | SM clock | pstate | Idle flag |
|---|---|---|---|---|---|
| Server up, serving traffic idle | ~42-45W | ~42-45W | 1230 MHz (pinned) | P0 | `Idle: Not Active` |
| Server up, SM clock locked (`-lgc 135,405`) | ~30W | ~31W | 405 MHz (capped) | P0 | — |
| Server stopped entirely | **~29W** | **~28W** | 135 MHz (floor) | P0 | — |

CPU threads on the vLLM workers were confirmed at 0% at the moment of
sampling (`ps -L`) — the elevated clock isn't a host-side busy-spin loop,
it's the driver simply not treating an open TP=2 CUDA/NCCL context as
"idle," regardless of actual traffic.

`-pl` (power limit) is irrelevant here: idle draw (42-45W) sits far under
even the tightened 200W cap, let alone the 100W floor — capping the
ceiling doesn't touch idle draw at all.

## Levers, in order of effect

1. **Stop the server** (`sudo systemctl stop v100-tp2-pcie.service`, or
   kill the `run.sh`/`serve-tp2-pcie.sh` tree) — releases the CUDA context
   entirely, true floor ~28-29W/GPU. Cost: full model reload on restart.
2. **`scripts/gpu-power.sh down`/`up`** — locks/unlocks the SM clock
   ceiling (`nvidia-smi -lgc 135,405` / `-rgc`) without stopping the
   server. ~30W/GPU while locked, full 1230MHz boost within ~1-2s of
   `up`. **Must `up` before sending a real request** — generation crawls
   at 405MHz while locked.
3. **`run.sh` power cap** (`POWER_LIMIT_W`, default 200W) — caps the
   *ceiling* under load, doesn't touch idle draw. Separate knob, separate
   purpose (thermal/noise headroom while serving, not idle savings).

## Autostart

`v100-tp2-pcie.service` (systemd, `WantedBy=multi-user.target`) was found
**enabled** — would auto-restart the server (and the idle draw) on every
boot. **Disabled** 2026-08-30 (`sudo systemctl disable v100-tp2-pcie.service`);
unit file untouched, re-enable with `sudo systemctl enable --now
v100-tp2-pcie.service` when persistent-on-boot serving is wanted again.

## Turing/consumer (RTX 2080) — not measured here, no such card on this box

Expected to idle lower than the V100s for three reasons, none confirmed
empirically: (1) no ECC overhead — consumer GeForce doesn't run ECC vRAM,
Tesla cards do by default; (2) desktop driver power management downclocks
idle SMs more aggressively than the datacenter/Tesla driver stack, which
is tuned for 24/7 rack readiness over idle efficiency; (3) single-GPU
inference has no NCCL communicator to keep a context "hot" — the
P0-pinning mechanism here is tied specifically to the live TP=2 collective
context, not merely "a model is resident in VRAM." A multi-2080 NCCL
tensor-parallel setup would plausibly show the same pinning pattern to
some degree; untested.
