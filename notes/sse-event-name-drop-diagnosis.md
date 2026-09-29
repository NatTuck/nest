# Dropped characters in LLM responses — root cause: SSE event name lost at chunk boundaries

**Verdict: it is a Nest streaming-parsing bug (H1), not the provider.**
DeepSeek is sending every character; `Nest.LLM.SSE.Parser` loses the named-event
(`event:`) metadata for some frames when the HTTP body is split across chunks, and
`Nest.LLM.AnthropicClient` silently discards frames whose event name is missing.

## Symptom

Characters (and whole JSON fragments / keys) vanish from assistant content. The
DeepSeek agents in `nest_dev` (`bottom-hawk-root` #133, `charming-rhinoceros-root`
#134, `surrounding-tiglon-root` #158) are affected; the raven-ferrus/vLLM agents
(OpenAI protocol) are not.

| agent | provider / protocol | tool calls | arg JSON bytes | "Missing required args" | shell syntax errors |
|---|---|---|---|---|---|
| 1 | raven-ferrus / openai | 164 | 103,786 | 0 | 0 |
| 93 | raven-ferrus / openai | 40 | 29,210 | 0 | 0 |
| 135 | raven-ferrus / openai | 63 | 41,376 | 0 | 0 |
| 133 | deepseek / anthropic | 170 | 45,234 | 10 | 7 |
| 134 | deepseek / anthropic | 365 | 123,606 | 31 | 6 |
| 158 | deepseek / anthropic | 455 | 192,561 | 55 | 2 |

On #134 the model repeatedly reports its own tool arguments being mangled
(e.g. msg 66: "The shell seems to mangle some inline characters"; msg 70:
"characters are randomly dropped"). Observed losses include `rm -rf` -> `rmrf`,
`mode=0777` -> `mode7`, `/tmp/tartest` -> `/tmpartest`, the JSON key `path` -> `""`,
and whole tool-call argument objects decoding to `{}`.

## Evidence

Raw wires were captured with `scripts/diagnose-sse-drops.exs` (real DeepSeek
calls) and replayed offline with `scripts/analyze-raw.exs`. All output is under
`notes/test-runs/` (`deepseek-raw-*.log`, `deepseek-diag-*.log`).

For a single captured stream (`notes/test-runs/deepseek-raw-1790639032.log`,
192,663 bytes, 1,357 `input_json_delta` fragments producing a 3,439-byte argument):

```
chunk=4096:   parser_deltas=1357 (3439B)  event_deltas=1324 (3347B)  equal=false
chunk=16384:  parser_deltas=1357 (3439B)  event_deltas=1346 (3408B)  equal=false
chunk=65536:  parser_deltas=1357 (3439B)  event_deltas=1355 (3433B)  equal=false
one chunk:    parser_deltas=1357 (3439B)  event_deltas=1357 (3439B)  equal=true
```

* The **raw bytes are clean**: the concatenated `partial_json` decodes to valid
  JSON containing all 3,374 requested characters (`raw_invalid_json?=false`).
* **`Parser.feed/2` is faithful**: its frame output matches the independent parse
  at every chunk size (1,357 fragments), including the whole stream in one chunk.
* **`AnthropicClient` loses fragments**: the canonical event stream has fewer
  `tool_call_delta` events than the parser produced, and the loss grows as the
  chunk size shrinks (33 lost at 4 KB, 11 at 16 KB, 2 at 64 KB, 0 at one chunk).
* Every lost frame has `event_name = nil` instead of `"content_block_delta"`:

  ```
  frames_with_input_json_delta_but_wrong_event_name=33 names=%{nil: 33}
  sample frame event=nil data="{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{...}}"
  ```

Minimal reproduction (no network):

```elixir
alias Nest.LLM.SSE.Parser
sse = "event: content_block_delta\ndata: {\"delta\":{\"type\":\"input_json_delta\"}}\n\n"

{fs, _} = Parser.feed(Parser.new(), sse)
hd(fs)                       # => {:event, "content_block_delta", ...}

{_, p} = Parser.feed(Parser.new(), "event: content_block_delta\n")
{fs2, _} = Parser.feed(p, "data: {\"delta\":{\"type\":\"input_json_delta\"}}\n\n")
hd(fs2)                      # => {:event, nil, ...}   <-- event name lost
```

## Root cause

1. `Nest.LLM.SSE.Parser.split_on_newlines/1` (`lib/nest/llm/sse/parser.ex:79-99`)
   splits the complete portion of the buffer with `String.split(complete, "\n")`.
   Because `complete` always ends in `\n`, the result always has a **trailing
   empty string**. When a chunk ends exactly on a line boundary, that trailing
   `""` is fed to `process_lines/2` as if it were a blank separator line.

2. `apply_line("", parser)` (`parser.ex:111-114`) calls `emit_pending_frame/1`.
   With no pending `data:` lines, `emit_pending_frame/1`
   (`parser.ex:130-132`) returns `%{parser | event_name: nil}` — **it clears a
   just-parsed `event:` name.**

3. If the chunk boundary falls after `event: content_block_delta\n` and before
   its `data:` line, the name is wiped before the data arrives. The frame is
   then emitted as `{:event, nil, data}`.

4. `Nest.LLM.AnthropicClient.frame_to_events/2` dispatches on the SSE event name
   (`lib/nest/llm/anthropic_client.ex:479` for `"content_block_delta"`, `:461`
   for `"content_block_start"`, `:437` `"message_start"`, etc.). A frame with
   `event_name: nil` matches none of these and is discarded by the catch-all
   `frame_to_events(_other, state)` at `anthropic_client.ex:545-546` **with no
   log or error**.

Net effect: that `input_json_delta.partial_json` fragment never reaches
`Nest.LLM.Client.accumulate/2` (`lib/nest/llm/client.ex:141-151`), so the
concatenated tool-call JSON is missing a run of characters (or, when the loss
breaks JSON syntax, `decode_arguments/1` at `client.ex:273-280` silently returns
`%{}`, producing "Missing required arguments").

### Why only the DeepSeek/Anthropic path?

The Anthropic wire format uses **named** SSE events (`event:` lines), and
`AnthropicClient` keys entirely off the event name. The OpenAI wire format is
`data:`-only, and `OpenAIClient.frame_to_canonical_event/1`
(`lib/nest/llm/openai_client.ex:342`) matches `{:event, _name, data}` — it
**ignores the event name**, so the parser defect is invisible on that path. This
is exactly why raven-ferrus/vLLM agents are clean and all DeepSeek agents are
corrupt.

### Why it varied run to run

The defect depends on where TCP/`Req` chunk boundaries fall. Smaller chunks (and
more of them) mean more boundaries after `event:` lines, hence more dropped
fragments. Nothing about the model or prompt is involved.

## Contributing robustness issues (why this was invisible)

* `AnthropicClient.frame_to_events/2` has a silent `_ -> {[], state}` fall-through
  for unrecognized frames (`anthropic_client.ex:545`); `OpenAIClient` has the same
  at `openai_client.ex:358`. A dropped frame produces no log or error.
* `Nest.LLM.Client.decode_arguments/1` silently returns `%{}` on JSON decode
  failure (`client.ex:279-280`), turning transport corruption into a bland
  "Missing required arguments" tool error.
* Both violate the AGENTS.md UI-transparency rule ("We don't quietly hide UI
  elements when expected data is missing").

## Fix applied

`lib/nest/llm/sse/parser.ex` — `split_on_newlines/1` now drops the trailing
empty string produced by `String.split(complete, "\n")` (since `complete`
always ends in `\n`) before feeding lines to `process_lines/2`:

```elixir
lines = complete |> String.split("\n") |> Enum.drop(-1)
{lines, rest}
```

Genuine blank separator lines are preserved (`"a\n\n"` -> `["a", ""]`), while a
chunk boundary right after a line's `\n` (`"event: x\n"` -> `["event: x"]`) no
longer synthesizes a phantom blank line that clears the pending `event:` name.

### Verification

Replaying the captured raw stream (`notes/test-runs/deepseek-raw-1790639032.log`)
through `AnthropicClient` at several chunk sizes now recovers the full argument
at every size:

```
chunk=4096:  wrong_event_name=0  event_deltas=1357  arg_bytes=3439  decoded_text_len=3374
chunk=16384: wrong_event_name=0  event_deltas=1357  arg_bytes=3439  decoded_text_len=3374
chunk=65536: wrong_event_name=0  event_deltas=1357  arg_bytes=3439  decoded_text_len=3374
```

(before the fix: 4 KB chunks gave 33 `wrong_event_name` frames and only
1324 deltas / 3347 bytes).

Regression tests added:
* `test/nest/llm/sse/parser_test.exs` — named-event stream split at **every byte
  offset**, plus byte-by-byte, must equal the whole-stream frame sequence with
  `event_name` intact. The prior test that encoded the buggy behavior (a lone
  `"data: hello\n"` emitting a frame) was corrected.
* `test/nest/llm/anthropic_client_sse_test.exs` — the same byte-offset sweep
  through `AnthropicClient.consume_sse_from_mailbox/1`, asserting identical
  canonical events (including both `tool_call_delta` fragments).

`mix precommit` is clean (credo, format, compile, line limits, full ExUnit +
JS suites).

## Remaining defense-in-depth (not implemented)

* In `AnthropicClient.frame_to_events/2`, surface unrecognized frames
  (log + `{:error, ...}` or at least a warning) instead of silently dropping them.
* In `Client.decode_arguments/1`, log on JSON decode failure rather than
  returning `%{}` silently.
* Make `emit_pending_frame/1` robust to a stray blank line arriving between an
  `event:` line and its `data:` line (per the SSE spec this clears the event
  type, so the parser-level fix above is the primary correction).


## Evidence artifacts

* `notes/test-runs/deepseek-raw-1790639032.log` — captured raw Anthropic SSE
  (one run, 192,665 bytes).
* `notes/test-runs/deepseek-diag-1790639032.log` — per-run analysis.
* `notes/test-runs/deepseek-raw-1790638776.log`, `...-1790638831.log`,
  `...-1790638894.log`, `...-1790638933.log` — additional captures (the
  `/v1` OpenAI-compatible control streams decode cleanly).
