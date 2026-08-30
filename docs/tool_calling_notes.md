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