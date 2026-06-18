# LLM Client Migration Status

## Overall: Phase 0 ✅ | Phase 1 ✅ | Phase 2 ✅ | Phases 3–6 ⏳

---

## Phase 0 — Define the boundary: ✅ DONE

All canonical types and behavior defined, tested, and working.

- `Nest.LLM.Client` behavior with `run/2`, `accumulate/2`, `finalize/2`
- `Nest.LLM.RunRequest` struct (messages, tools, model, system, api_opts, tool_choice)
- `Nest.LLM.RunResponse` struct (text, thinking, thinking_signature, tool_call_events, status, usage)
- `Nest.LLM.Tool` struct (name, description, parameters_schema, function callback)
- `Nest.LLM.ToolResult` struct
- `Nest.LLM.ClientConfig` struct (client module + config + legacy escape hatch)
- `Nest.LLM.MockClient` implementing the Client behavior (FIFO script queue)
- `Nest.LLM.SSE` line-buffered parser
- `Nest.LLM.OpenAIClient` with `format_request_payload/2`
- `Nest.LLM.Tools` executor — Nest-native, replaces `LLMChain.execute_tool_calls/3`
- `Nest.ChatModel.new/1` returns `ClientConfig`; `new!/1` raising variant
- `Nest.Tools` refactored to produce `Nest.LLM.Tool` structs with JSON string-key schemas

---

## Phase 1 — Real Req streaming for OpenAI path: ✅ DONE

- Agent core refactor: `:chain` → `:client_config`, `RunContext` / `RunState` structs
- `consume_new_stream/4` broadcasts `chat:delta` to PubSub with `chars_start`/`chars_end`
- `normalize_response/2` uses the accumulator as the source of truth for `tool_calls`
- `Nest.LLM.MockClient` uses a FIFO queue so `set_tool_response` then `set_response` work in order
- `lib/nest/messages/message.ex` empty-list serializer fix
- All `test/nest_web/channels/agent_channel_test.exs` and `test/nest/agents/agent_test.exs` LangChain references swapped to `Nest.LLM.OpenAIClient` / `Nest.LLM.MockClient`

---

## Phase 2 — Anthropic native client: ✅ DONE

### `Nest.LLM.AnthropicClient` (new)

- Implements `Nest.LLM.Client` behavior
- Wire format: Anthropic `POST /v1/messages` with SSE named events
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
- Translates all named SSE events to canonical events:
  - `message_start` → captures model + `usage.input_tokens`
  - `content_block_start` (tool_use) → `{:tool_call_start, %{id, name, index}}`
  - `content_block_start` (thinking + signature) → `{:thinking_signature, sig}`
  - `content_block_delta` (text_delta) → `{:text, text}`
  - `content_block_delta` (thinking_delta) → `{:thinking, text}`
  - `content_block_delta` (signature_delta) → `{:thinking_signature, sig}`
  - `content_block_delta` (input_json_delta) → `{:tool_call_delta, %{id: :by_index, index, arguments_delta}}`
  - `message_delta` → `{:finish_reason, reason}` + `{:usage, output_tokens}`
  - `message_stop` → `{:done, %{response: ...}}`
  - `error` → `{:error, data}`
- Wire request shape:
  - System prompt lifted out into top-level `"system"` field (not a message)
  - Assistant messages rebuilt as content blocks: `text`, `thinking` (with `signature`), `tool_use`
  - Tool results placed in a user-role message with `tool_result` content blocks
  - `tool_choice: :required` falls back to `:auto` (Anthropic has no equivalent)
  - Default `max_tokens: 4096` (Anthropic requires it)
- Public-for-testing `consume_sse_from_mailbox/0` so the SSE translation is testable without going through Req
- 18 tests covering wire format and SSE translation, including thinking_signature capture from both `content_block_start.signature` and `signature_delta` events

### `lib/nest/chat_model.ex`

- `build_anthropic_config/2` now uses `Nest.LLM.AnthropicClient` (was `:langchain_legacy` + `%ChatAnthropic{}`)
- `:langchain_legacy` no longer referenced anywhere
- `build_chat_model/2` and `build_openai_legacy/2` / `build_anthropic_legacy/2` kept for the API key resolution tests (they exercise the LangChain-side resolver, which is just a wrapper around `DotConfig.resolve_api_key`)

### `lib/nest/agents/agent.ex`

- `run_chain_with_callbacks/2` simplified to a single `run_with_new_client/2` call (was a case split on `:langchain_legacy`)
- ~480 lines of legacy LangChain helpers removed (`run_with_legacy_client/8`, `convert_to_langchain_messages/1`, `create_chain_with_messages/2`, `run_and_handle_response/2`, `handle_successful_response/3`, `handle_tool_calls/3`, `handle_run_response/2`, `run_with_tool_handling/2`, `run_chain_and_handle_response/2`, `continue_with_tool_results/2`, `finalize_tool_response/6`, `extract_thinking/1`, `extract_text_content/1`, `extract_content_segments/1`, `part_to_segment/1`, `stream_segments/4`, `chunk_content/2`, `build_tool_call/2`, `build_tool_result/2`, `extract_tool_content/1`, `build_api_response/1`, plus the LangChain aliases)
- `build_tool_pair/3` now also writes `metadata: %{"thinking_signature" => sig}` on the assistant message when Anthropic extended thinking is enabled
- New `handle_info({:thinking_signature_received, sig}, state)` updates the streaming accumulator's `thinking_signature` field
- `consume_new_stream/4` sends `{:thinking_signature_received, sig}` to the agent pid when a `:thinking_signature` event arrives
- `normalize_response/2` now also folds `thinking_signature` from the accumulator into the response
- `:llm_response_with_thinking/3` handler writes the signature into the persisted Assistant's `metadata` so it round-trips through subsequent turns

### Full suite

- **328 tests, 0 failures** (was 310; +18 AnthropicClient tests)
- `mix compile --warnings-as-errors` clean
- `mix format --check-formatted` clean
- `mix credo` 0 issues

---

## Phase 3 — Tool execution shim: ⏳ NOT STARTED

- `LangChain.Message.ToolCall` type in `Agent.load_saved_messages` (line 411) — referenced by `Nest.Tools` deserialization. Needs conversion to `%{id:, name:, arguments:}` plain maps. This is now the only LangChain reference in `lib/nest/agents/agent.ex`.
- `build_chat_model/2` and the `build_*_legacy/2` helpers in `chat_model.ex` are still LangChain-touching (they're only kept for the API key resolution tests; can be deleted or simplified in Phase 5).

---

## Phase 4 — Port the test mock: ✅ DONE (as part of Phase 1)

- `Nest.LLM.MockClient` implements the `Client` behavior with a FIFO queue
- `test/support/lang_chain_mock.ex` (358 lines) is no longer referenced from any test — safe to delete in Phase 5
- All `Mimic.stub_with` and `Mimic.stub` calls in `test/` now target `Nest.LLM.OpenAIClient` (the new copy target) or `Nest.LLM.MockClient` directly

---

## Phase 5 — Drop the dep: ⏳ NOT STARTED (now mechanically easy)

- Remove `:langchain` from `mix.exs`
- Delete `deps/langchain/` (auto via deps.get)
- Delete `test/support/lang_chain_mock.ex`
- Delete `message.ex` ContentPart special case (lines 70-83) — now dead since the new path doesn't emit `%LangChain.Message.ContentPart{}`
- Delete `build_chat_model/2` and the `build_*_legacy/2` helpers in `chat_model.ex`
- Remove the `LangChain.Message.ToolCall` deserialization branch in `Nest.Tools`

After Phase 5, no LangChain code remains in `lib/`. Only `test/support/lang_chain_mock.ex` (dead) and the `mix.exs` entry remain.

---

## Phase 6 — Real-time thinking: ✅ DONE (as part of Phase 2)

- OpenAI reasoning model deltas are wired through `consume_new_stream` (the new `broadcast_delta_text` + `send(agent_pid, {:delta_received, _, :thinking})` path). The persisted `assistant.thinking` field is populated when the OpenAIClient's `delta_events` extracts `reasoning_content` → `:thinking`.
- Anthropic thinking + signature capture is wired through Phase 2: `AnthropicClient` emits `:thinking` and `:thinking_signature` events, the agent stores the signature in `metadata["thinking_signature"]` on the persisted Assistant message, and the `AnthropicClient` reads it back when rebuilding assistant content blocks for the next request.

---

## Key files state

| File | Status |
|------|--------|
| `lib/nest/llm/client.ex` | ✅ Done |
| `lib/nest/llm/run_request.ex` | ✅ Done |
| `lib/nest/llm/run_response.ex` | ✅ Done |
| `lib/nest/llm/client_config.ex` | ✅ Done |
| `lib/nest/llm/tool.ex` | ✅ Done |
| `lib/nest/llm/tool_result.ex` | ✅ Done |
| `lib/nest/llm/tools.ex` | ✅ Done |
| `lib/nest/llm/mock_client.ex` | ✅ Done (FIFO queue) |
| `lib/nest/llm/sse/parser.ex` | ✅ Done |
| `lib/nest/llm/openai_client.ex` | ✅ Done |
| `lib/nest/llm/anthropic_client.ex` | ✅ Done (Phase 2) |
| `lib/nest/chat_model.ex` | ✅ Done (AnthropicClient wired; legacy helpers kept for tests) |
| `lib/nest/tools.ex` | ✅ Done (produces Nest.LLM.Tool) |
| `lib/nest/agents/agent.ex` | ✅ Done (single new path for both providers; thinking_signature echo-back) |
| `lib/nest/messages/message.ex` | ⚠️ Empty-list fix; LangChain ContentPart branch still present but dead |
| `test/nest/llm/*` | ✅ 66 tests passing (48 + 18 AnthropicClient) |
| `test/nest/tools_test.exs` | ✅ 30 tests passing |
| `test/nest/agents/agent_test.exs` | ✅ 29 tests passing |
| `test/nest_web/channels/agent_channel_test.exs` | ✅ 41 tests passing |
| `test/nest/chat_model_test.exs` | ✅ 32 tests passing |
| `test/test_helper.exs` | ✅ Updated |
| `test/support/lang_chain_mock.ex` | ⏳ Not used; delete in Phase 5 |
