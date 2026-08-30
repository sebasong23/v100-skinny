#!/usr/bin/env bash
# Tool-calling smoke test for the Duo-V100 vLLM server.
# Usage:  bash /tmp/test-tool-calling.sh [base_url]   (default http://127.0.0.1:8000)
set -uo pipefail
BASE="${1:-http://127.0.0.1:8000}"
API="$BASE/v1/chat/completions"

TOOLS='[{"type":"function","function":{"name":"pwsh","description":"Execute a PowerShell command and return stdout/stderr.","parameters":{"type":"object","properties":{"command":{"type":"string"},"description":{"type":"string"}},"required":["command","description"]}}}]'

PARSER="$(
cat <<'PYEOF'
import json, sys

def handle_choice(ch):
    dd = ch.get("delta") or {}
    msg = ch.get("message") or {}
    tc = dd.get("tool_calls")
    if tc is None:
        tc = msg.get("tool_calls")
    if tc:
        args = []
        for t in tc:
            fn = t.get("function", {})
            if fn.get("name"):
                print("tool name:", fn["name"])
            a = fn.get("arguments")
            if a:
                args.append(a)
        if args:
            print("  args  :", "".join(args))
    for kind in ("reasoning", "content"):
        for src in (msg, dd):
            v = (src or {}).get(kind)
            if v:
                print(kind + " :", repr(v))
                break
    fr = ch.get("finish_reason")
    if fr is not None:
        print("finish :", fr)

raw = sys.stdin.read().strip()
if raw.startswith("{"):
    try:
        j = json.loads(raw)
        for ch in j.get("choices", []):
            handle_choice(ch)
    except Exception as e:
        print("parse error:", e)
else:
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        d = line[5:].strip()
        if d == "[DONE]":
            continue
        try:
            j = json.loads(d)
        except Exception:
            continue
        for ch in j.get("choices", []):
            handle_choice(ch)
PYEOF
)"

run() {  # name, extra_body_json
  local name="$1" extra="$2"
  printf '\n=== %s ===\n' "$name"
  curl -s -N "$API" -H 'Content-Type: application/json' -d "{
    \"model\": \"qwen3.8-27b\",
    \"messages\": [{\"role\":\"user\",\"content\":\"Use the pwsh tool to list files in the current directory.\"}],
    \"tools\": $TOOLS,
    $extra
    \"max_tokens\": 300,
    \"temperature\": 0
  }" | python3 -c "$PARSER"
}

run "1) tool_choice AUTO (non-stream)" '"tool_choice":"auto",'
run "2) tool_choice AUTO (stream)"    '"tool_choice":"auto","stream":true,'
run "3) tool_choice REQUIRED"         '"tool_choice":"required",'
run "4) tool_choice NAMED (forced pwsh)" '"tool_choice":{"type":"function","function":{"name":"pwsh"}},'

cat <<'EXPECT'

PASS criteria after the fix:
  1&2) tool name "pwsh" then arguments = {"command": ..., "description": ...}
  3)   a real tool_calls entry (NOT []) with JSON args
  4)   arguments is JSON (NOT raw <tool_call> XML)

If 3/4 fail, the server has NOT been restarted with the patch:
  stop the old process, then re-run ./run.sh
EXPECT