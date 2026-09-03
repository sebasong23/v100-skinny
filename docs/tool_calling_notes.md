# Tool calling fixes — V100 NVIDIA 2026-08-30

The RadixArk Qwen3.8-27B NVFP4 server (run.sh → serve-tp2-pcie.sh,
`--tool-call-parser qwen3_coder`) returned empty/garbage `tool_calls` for
clients that force a tool, which surfaced on the DeepSeek harness as repeated
`INVALID_ARGS` for calls like `wsh{}` / `pwsh{}` (a tool call whose arguments
were lost or mangled). All tool-choice modes were tested against the live
server; two were broken by the same routing bug.

## Repro over `/v1/chat/completions` (qwen3.8-27b)

| `tool_choice` | Result | Verdict |
|---|---|---|
| `auto` (streaming + non-streaming) | `tool_calls:[{name:"pwsh",arguments:"{\"command\":\"Get-ChildItem\",...}"}]` streamed token-by-token | works |
| `required` | `finish_reason:"tool_calls"` but `tool_calls:[]`, `content:""` | **broken** |
| named forced (`{"type":"function","function":{"name":"pwsh"}}`) | `arguments` = the raw `\n<tool_call>\n<function=pwsh>\n<parameter=command>...` XML blob | **broken** |

The model itself is fine: with `tool_choice:"none"` it emits well-formed Qwen
XML — `<tool_call><function=pwsh><parameter=command>…` — which
`Qwen3CoderToolParser.extract_tool_calls` parses correctly (verified offline
against both one-line and newline-wrapped variants).

## Root cause

`Qwen3CoderToolParser.supports_required_and_named` defaulted to `True`
(`not VLLM_ENFORCE_STRICT_TOOL_CALLING`). The parser emits Qwen XML, never
OpenAI JSON function definitions. With the flag `True`, the serving layer
`_parse_tool_calls_from_content` (vllm/entrypoints/openai/engine/serving.py)
short-circuits `required`/named requests into JSON-based reconstruction and
never calls the XML extractor:

- `required` → `TypeAdapter(list[FunctionDefinition]).validate_json(content)`
  fails silently on XML → `tool_calls: []`, content cleared, `finish_reason`
  still `tool_calls`.
- named → `FunctionCall(name=…, arguments=raw XML text)` → the arguments are
  the unparseable XML blob; a client's JSON arg-validator returns
  `INVALID_ARGS`.

The XML path works for every mode, so it must not be bypassed.

## Fix

Forced `supports_required_and_named = False` on `Qwen3CoderToolParser`, so
`required`/named requests route through the XML extractor (the same routing
the `auto` mode already uses; matches the GLM4 parser precedent). One behavioral
note: with strict tool calling assumed off, the sole semantic change is that
forced-named calls now parse the emitted XML instead of treating the XML as
the arguments string.

Files changed:

- `fork_patches/qwen3coder_tool_parser.py` (new; header documents the edit) →
  installed at `vllm/tool_parsers/qwen3coder_tool_parser.py`
- `scripts/bootstrap-sm70.sh` (deploy line)
- `fork_patches/README.md` (table row)
- `scripts/test-tool-calling.sh` (new; smoke test described below)

The patched file is staged over the installed wheel (kept `.pre_bootstrap`
backup). **A server restart is required** — the running process holds the old
class in memory. `./run.sh` (or `HOST=… PORT=… ./run.sh` as usual).

## Verification — executed 2026-08-30 (after restart at 10:25:10)

One script exercises all four tool-choice modes against the live server:
[`scripts/test-tool-calling.sh`](../scripts/test-tool-calling.sh). Run it with:

```bash
bash scripts/test-tool-calling.sh            # defaults to http://127.0.0.1:8000
bash scripts/test-tool-calling.sh http://192.168.1.153:8000   # remote LAN
```

It sends one message with a `pwsh` tool schema and asserts per mode:

- 1) `tool_choice: auto`, non-streaming
- 2) `tool_choice: auto`, `stream: true`
- 3) `tool_choice: required`
- 4) `tool_choice: {"type":"function","function":{"name":"pwsh"}}` (named/forced)

### Actual results (post-fix)

Every mode returned the same well-formed call — this is the pre-fix `required`
and named responses shown in the repro table above, fixed:

```
1) tool name: pwsh
   args  : {"command": "Get-ChildItem", "description": "List files in the current directory"}
   finish : tool_calls

2) (streamed deltas) tool name: pwsh, args streamed as { "command": … , "description": … }
   finish : tool_calls

3) tool name: pwsh
   args  : {"command": "Get-ChildItem", "description": "List files in the current directory"}
   finish : tool_calls

4) tool name: pwsh
   args  : {"command": "Get-ChildItem", "description": "List files in the current directory"}
   finish : stop          # cosmetic only; arguments are still proper JSON
```

Pass criteria met: `required` returns a real `tool_calls` entry (was `[]`),
and named returns JSON arguments (was the raw `<tool_call>` XML blob).
`finish_reason: stop` on the forced-named case is a minor protocol quirk —
the call and arguments are correct, so clients should not treat it as a
failure.

## Follow-up investigation 2026-08-30 10:45 — "empty pwsh{}" still occurring

After the fix, the DeepSeek Harness (Windows box on the LAN) still reported
`pwsh{}` → `INVALID_ARGS` inside a real Vue/PHP/SQLite todo-list task, while the
same session's `todo_write` and `write` calls succeeded. A raw HTTP capture of
the harness traffic (`tcpdump -i any -A port 8000`) settled it — **not a server
bug, not a line-ending issue**.

### Evidence from the capture

- The harness streams (`"stream":true`, **no `tool_choice`** → auto), sending a
  huge system prompt, 24 tools, history containing four prior `pwsh`
  `arguments:"{}"` failures, and `max_completion_tokens: 32000`.
- In the responses, `write` and `todo_write` stream full argument deltas
  (`{`, `"file_path":…`, `"content":…`, `}`) — through the **same** XML parser,
  **same** stream. `pwsh` streamed a header `name="pwsh"` then a single
  `arguments:"{}"`. Five times in a row.
- The server therefore relays the model faithfully: the model literally emits
  `<function=pwsh>` with **no parameters** in that heavy context.

### Ruled out

| Hypothesis | Verdict |
|---|---|
| CRLF/LF Windows-vs-Linux (the "ln" question) | No — client JSON and server output both use LF; arguments are regenerated server-side, not echoed |
| Long tool description (~1800-char `pwsh` sandbox policy) | No — reproduced locally with a 1870-char description; 3/3 full args |
| Parser dropping args in streaming | No — `write`/`todo_write` survive the identical stream |
| `tool_choice` routing (the earlier fix) | Confirmed working; unrelated to this symptom |

### Diagnosis

Model behaviour, not transport/parsing: under the harness's heavy context
(huge system prompt + 24 tools + long degraded history), RadixArk Qwen3.8-27B
falls into a **degeneration loop** — four identical empty `pwsh` calls with the
same reasoning ("Let's create the directory and check the PHP version.").
Signature is consistent with **MTP speculative-decoding degeneracy** (K=7
draft) or long-chain-of-thought rationalisation of repeated failures. It is
context-specific: short-context reproductions always emit full arguments.

### Recommended follow-ups (run.sh env toggles, in order)

1. `NOSPEC=1 ./run.sh` — disable the MTP drafter; breaks draft-driven
   repetition loops.
2. `THINKING=false ./run.sh` — drop the chain-of-thought that rationalises the
   empty retries.
3. Harness-side: shorten the `pwsh` tool description (the ~1800-char Windows
   sandbox lecture is most of the condition).

Not yet executed — server was still serving the fix at the time of writing.

## Residual caveats

- `arguments` still requires whatever the tool schema marks `required`
  (`pwsh` needs `command` + `description`). `INVALID_ARGS` for a genuinely
  empty `{}` is correct client-side behaviour, not a server bug.
- `tool_choice:"required"` with streaming was not part of the executed matrix
  (mode 3 ran non-streaming). Structurally it now routes through the same XML
  parser that mode 2 exercises streaming, but re-verify if you rely on it.
- The reasoning block (`reasoning` field) precedes content correctly; a
  leading `\n\n` content chunk is emitted before the tool call in streaming —
  harmless, clients typically trim.

## Follow-up 2026-09-02 — `NOSPEC=1 ./run.sh` fixes the tool-call mangling

The `edit`-tool failure in opencode (Windows box on the LAN → this server at
`http://192.168.1.153:8000/v1`) was the *same* malformed-tool-call signature
predicted above, but even more visible: opencode's heavier context (large
system prompt + ~10 tools + real file contents) made the model emit an `edit`
call whose `arguments` were mangled / truncated with a trailing `{}`
(`{"filePath": "...", "oldString": "...", {...{}`), which the client then
rejected as invalid JSON.

Confirmed this was model-side, not transport/parser: the qwen3_coder parser
patch was already installed and the running server was started after it, so
the routing fix was active. The speculative config (`num_speculative_tokens=7`,
K=7 MTP) was still on — the exact condition the earlier diagnosis flagged.

### Resolution

Restart with the MTP drafter disabled:

```bash
NOSPEC=1 ./run.sh
```

After restart, `scripts/test-tool-calling.sh` against `http://127.0.0.1:8000`
passed all four modes (auto non-stream, auto stream, required, named-forced)
with full JSON arguments — no empty `{}` and no raw XML blob. Note: same
restart also revealed a (harmless) side effect — the first request still runs
the one-time warmup (weight prepack + torch.compile + CUDA-graph capture),
which takes ~2 min and briefly shows 0.0 tok/s with
`shm_broadcast: No available shared memory broadcast block` warnings. That is
warmup, not a hang.

### run.sh default change

While verifying, `run.sh` was also changed to default `NOPREFIXCACHE=0`
(prefix caching **on**); `--no-enable-prefix-caching` is no longer passed by
default. Re-enable with `NOPREFIXCACHE=1 ./run.sh` if needed. This did not
appear to affect tool calling either way.

### Not yet ruled out

- `THINKING=false ./run.sh` (docs step 2) was **not** needed in the
  short/medium-context smoke test, but is still the next lever if a heavy
  opencode context regresses again.
- Full opencode end-to-end `edit` on a real file with large context is the
  definitive regression check; re-test there before calling it fixed.

## Follow-up 2026-09-03 — tried swapping in froggeric's chat template to avoid `NOSPEC=1`

`NOSPEC=1` fixes the tool-call mangling but roughly halves throughput
(~70 tok/s → ~35 tok/s). Investigated whether the mangling was actually a
chat-template bug (as opposed to the MTP degeneracy already diagnosed above)
by trying [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates)
(`chat_template.jinja`, tagged `qwen3.8-froggeric-v22.4`, explicitly targets
`Qwen3.8-27B`) with speculative decoding left **on**.

### What changed

- `RadixArk_Qwen3.8-27B-NVFP4/chat_template.jinja` replaced with froggeric's
  version. Original backed up alongside it as
  `chat_template.jinja.bak-20260903-214657` (restore by copying that back
  over `chat_template.jinja`). This checkpoint directory is gitignored, so
  this change is filesystem-only — not a git commit.
- `serve-tp2-pcie.sh` / `run.sh` **unchanged**. In particular still
  `--tool-call-parser qwen3_coder` (the already-patched
  `fork_patches/qwen3coder_tool_parser.py`), **not** the newer built-in
  `qwen3_xml` parser — checked its source
  (`vllm/tool_parsers/qwen3xml_tool_parser.py`, vLLM 1.2.2) and it does not
  override `supports_required_and_named`, so it defaults to `True` and would
  reintroduce the exact `required`/named routing bug the qwen3_coder patch
  above already fixed. froggeric's template defaults to the same
  `tool_call_format="xml"` (`<tool_call><function=...><parameter=...>`)
  output as the original template, so it stays compatible with the patched
  `qwen3_coder` parser without any serve-script changes.
- Verified offline with a plain jinja2 render (tools + assistant tool_calls +
  tool response) before touching the live server — renders cleanly, same XML
  shape as before.
- Restarted with plain `./run.sh` (`NOSPEC` unset → `0`, spec decoding **on**,
  K=7 MTP as usual). `scripts/test-tool-calling.sh` passed all four
  tool_choice modes (auto non-stream, auto stream, required, named-forced)
  with clean JSON arguments.

### Caveat — not yet a real fix, just not yet disproven

`scripts/test-tool-calling.sh` is a **short-context** smoke test that has
always passed, even before this change and even with spec decoding on — it
never exercised the actual bug. The mangling this template swap was meant to
fix only appeared under **heavy context** (opencode/DeepSeek-harness: large
system prompt, 10-24 tools, long history) and was diagnosed above as MTP
speculative-decoding degeneracy, not a template bug. froggeric's docs don't
mention MTP or speculative decoding at all — its fixes are for template
rendering (JSON-string tool-arg crashes, empty-think handling, rendering
errors), so there's no specific reason to expect it fixes a decoding-time
degeneracy.

**Net: template swap done, spec decoding left on, short-context test passes,
but the real regression check — a heavy-context opencode/harness session —
has not been run against this combination yet.** If the mangling recurs,
this template swap did not fix it; fall back to `NOSPEC=1` (or try lowering
`K`, e.g. `K=2 ./run.sh`, as an untested middle ground) and consider
reverting `chat_template.jinja` from the `.bak-20260903-214657` copy (though
reverting the template is not expected to matter either way, since it wasn't
implicated).