#!/usr/bin/env python3
"""Heavy-context regression harness for V100 qwen3.8-27b tool-call JSON.

Simulates an opencode-style session that reproduces the 2026-09-04 incident
signature: `arguments` arriving truncated/mangled at the closing brace (JSON
parse "Expected '}'"). Tools: read/edit/grep/bash/write. Real file contents
are fed back as tool results so context stays heavy, like opencode. Every
tool call's reassembled arguments are validated; any malformed call is dumped
to /tmp/opencode/fail_*.txt.

Exit code: 0 = no malformed tool calls (fix holds), 1 = reproduced.

Usage: python3 scripts/tool-args-regression.py [base_url] [turns]
"""
import json
import os
import sys
import time
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
API = BASE + "/v1/chat/completions"
MODEL = "qwen3.8-27b"

PROJECT = "/home/sebasong/v100-qwen38/v100-skinny"
TARGET = os.path.join(PROJECT, "serve-tp2-pcie.sh")

TOOLS = [
    {"type": "function", "function": {"name": "read", "description": "Read a file from the filesystem. If offset/limit are not given returns from the start of the file. Optional: pass offset and limit to read just a range.", "parameters": {"type": "object", "properties": {"filePath": {"type": "string", "description": "Absolute path to file to read"}, "offset": {"type": "number", "description": "Number of lines to skip from the start"}, "limit": {"type": "number", "description": "Max number of lines to read"}}, "required": ["filePath"]}}},
    {"type": "function", "function": {"name": "edit", "description": "Edit an existing file using the exact old string match. Provide oldString (exact text to be replaced, must match exactly, including quotes/backticks) and newString (the replacement).", "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}, "oldString": {"type": "string", "description": "The text to replace, exact match"}, "newString": {"type": "string", "description": "The replacement text"}}, "required": ["filePath", "oldString", "newString"]}}},
    {"type": "function", "function": {"name": "grep", "description": "Search files for a regex pattern, return file:line matches.", "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string"}}, "required": ["pattern", "path"]}}},
    {"type": "function", "function": {"name": "bash", "description": "Execute a shell command and return stdout/stderr.", "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}},
    {"type": "function", "function": {"name": "write", "description": "Write a new file with given content.", "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}, "content": {"type": "string"}}, "required": ["filePath", "content"]}}},
]

REQUIRED = {
    "read": ["filePath"],
    "edit": ["filePath", "oldString", "newString"],
    "grep": ["pattern", "path"],
    "bash": ["command"],
    "write": ["filePath", "content"],
}

SYSTEM = """You are an autonomous senior backend engineer working at a shell on a Linux box.
You edit PHP/Vue code. Environment notes:
- Use the `read` tool to inspect files; pass offset/limit to read ranges.
- Use the `edit` tool ONLY with an exact oldString match from the file contents you actually saw.
- The `grep` tool searches a directory tree for a regex.
- The `bash` tool runs a shell command.

Rules:
- Never invent file contents. Read first, then edit with exact anchors.
- Keep code snippets exactly as written; do not normalize whitespace.
- If an edit failed, re-read the surrounding lines and retry with a longer unique anchor.
- The file you will work on: */home/sebasong/v100-qwen38/v100-skinny/serve-tp2-pcie.sh"""

TASKS = [
    f"Read {TARGET} from line 1 to 120 and report what the main env vars are.",
    f"In {TARGET}, the EAGER/NOSPEC flags are set by env vars. Find the exact lines with `EAGER=\"${{EAGER:-0}}\"` and `NOSPEC=\"${{NOSPEC:-0}}\"`, then use edit to prepend a comment line '# repro-diagnostic' right before the EAGER line. Do it with a precise oldString.",
    f"In {TARGET}, append a new diagnostic stanza after the '# PCIe FIX #1' comment. First read the block around it, then edit. The insertion must keep the shell syntax valid.",
    f"Grep {PROJECT} for 'TORCH_CUDA_ARCH_LIST' and 'NCCL_P2P_DISABLE', show me every occurrence with the file and line.",
    f"Read the section of {TARGET} between the '# GPU occupancy guard' comment and 'exec env'. Then use edit to change the GMU default from 0.9 to 0.85. Use a long, exact anchor.",
    f"Back out: in {TARGET}, remove the '# repro-diagnostic' line you added. Read the area first, then edit.",
    f"Write a new shell script {PROJECT}/results/toolcheck_probe.sh containing a POWER_LIMIT function with double quotes and backticks in the echo, then read it back and confirm.",
]


def post(payload, timeout=900):
    req = urllib.request.Request(API, json.dumps(payload).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def stream_turn(payload):
    raw = post(payload).decode("utf-8", "replace")
    calls, content = {}, []
    with open("/tmp/opencode/last_stream_body.txt", "w") as _bf:
        _bf.write(raw)
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
            dd = ch.get("delta") or {}
            if dd.get("content"):
                content.append(dd["content"])
            for tc in (dd.get("tool_calls") or []):
                idx = tc.get("index", 0)
                fn = tc.get("function") or {}
                c = calls.setdefault(idx, {"name": None, "args": "", "chunks": []})
                if fn.get("name"):
                    c["name"] = fn["name"]
                a = fn.get("arguments")
                if a:
                    c["args"] += a
                    c["chunks"].append(a)
    return calls, "".join(content)


def non_stream_turn(payload):
    p = dict(payload)
    p["stream"] = False
    j = json.loads(post(p))
    calls, content = {}, ""
    for ch in j.get("choices", []):
        msg = ch.get("message") or {}
        content += msg.get("content") or ""
        for tc in (msg.get("tool_calls") or []):
            fn = tc.get("function") or {}
            calls[tc.get("index", 0)] = {"name": fn.get("name"), "args": fn.get("arguments") or "", "chunks": []}
    return calls, content


fail_no = [0]


def verdict(fn, args):
    if not args:
        return "EMPTY_ARGS"
    try:
        obj = json.loads(args)
    except Exception as e:
        return f"JSON_ERROR{str(e)}"
    miss = [k for k in REQUIRED.get(fn, []) if k not in obj]
    return f"MISSING{miss}" if miss else None


def check(calls, tag, dump=True):
    probs = []
    for idx, c in sorted(calls.items()):
        v = verdict(c["name"], c["args"])
        if v:
            probs.append((idx, c["name"], v, c["args"]))
            if dump:
                fail_no[0] += 1
                path = f"/tmp/opencode/fail_{fail_no[0]}_{tag}.txt"
                with open(path, "w") as f:
                    f.write(f"[{tag}] tool={c['name']} verdict={v}\nREASSEMBLED ARGS:\n{c['args']!r}\n\nCHUNKS:\n{json.dumps(c['chunks'], ensure_ascii=False)}\n")
                print(f"  *** FAIL {v} tool={c['name']} -> {path}")
    if not probs:
        print(f"  ok [{tag}] tools={[c['name'] for c in calls.values()]}")
    return probs


def exec_tool(name, args):
    # mirror opencode: return real content for read/grep/bash, canned for edit/write
    try:
        a = json.loads(args)
    except Exception:
        return "ERROR: could not parse arguments"
    if name == "read":
        fp = a.get("filePath")
        try:
            lines = open(fp).read().splitlines()
        except Exception as e:
            return f"ERROR reading {fp}: {e}"
        off = int(a.get("offset") or 1)
        lim = int(a.get("limit") or len(lines))
        return "\n".join(lines[off - 1: off - 1 + lim]) or "(empty)"
    if name == "grep":
        import subprocess
        try:
            out = subprocess.run(["grep", "-rn", a.get("pattern", ""), a.get("path", PROJECT)],
                                 capture_output=True, text=True, timeout=30)
            return out.stdout[:4000] or "(no matches)"
        except Exception as e:
            return f"grep error: {e}"
    if name == "bash":
        import subprocess
        try:
            out = subprocess.run(["bash", "-c", a.get("command", "")], capture_output=True, text=True, timeout=30)
            return (out.stdout + "\n" + out.stderr)[:4000] or "(done)"
        except Exception as e:
            return f"bash error: {e}"
    if name == "edit":
        return "Edit applied successfully."
    if name == "write":
        return "File created successfully."
    return "ok"


def main():
    turns = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    messages = [{"role": "system", "content": SYSTEM}]
    total_bad = 0
    t0 = time.time()
    for tn in range(turns):
        task = TASKS[tn % len(TASKS)]
        messages.append({"role": "user", "content": task})
        print(f"\n=== turn {tn} (elapsed {time.time()-t0:.0f}s) task: {task[:70]}...")
        steps_taken = 0
        for step in range(6):
            payload = {"model": MODEL, "messages": messages, "tools": TOOLS,
                       "tool_choice": "auto", "stream": True, "temperature": 0.4,
                       "max_tokens": 2500}
            calls, _ = stream_turn(payload)
            probs = check(calls, f"t{tn}s{step}")
            if probs:
                try:
                    import shutil
                    shutil.copy("/tmp/opencode/last_stream_body.txt", f"/tmp/opencode/failbody_t{tn}s{step}.txt")
                except Exception:
                    pass
            total_bad += len(probs)
            if probs:
                # extra diagnostic: re-run same request non-streaming to split parser vs model
                print("  -> re-running last request non-streaming for comparison...")
                calls2, _ = non_stream_turn(payload)
                print("  -> non-stream comparison:")
                check(calls2, f"t{tn}s{step}_nonstream", dump=False)
            if not calls:
                messages.append({"role": "assistant", "content": "I could not find a reason to call a tool."})
                break
            for idx, c in sorted(calls.items()):
                try:
                    a = json.loads(c["args"])
                    repaired = c["args"]
                except Exception:
                    a = {}
                    repaired = json.dumps(a, ensure_ascii=False)
                cid = f"call_{tn}_{step}_{idx}"
                messages.append({"role": "assistant", "tool_calls": [{"id": cid, "type": "function", "function": {"name": c["name"], "arguments": repaired}}]})
                result = exec_tool(c["name"], repaired)
                messages.append({"role": "tool", "tool_call_id": cid, "content": result})
            steps_taken += 1
            if all(c["name"] in ("edit", "write") for c in calls.values()):
                break
    print(f"\nDONE: {total_bad} malformed tool calls across {turns} turns; dumps in /tmp/opencode/fail_*.txt")
    sys.exit(1 if total_bad else 0)


if __name__ == "__main__":
    main()