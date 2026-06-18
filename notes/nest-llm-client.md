# Nest LLM client

Replacing the LangChain dependency with a Nest-native LLM client backed by Req.

## Why

The LangChain dep (`~> 0.8.0`) is the seam where several things happen at once: HTTP/SSE parsing for OpenAI + Anthropic, transient DTO shapes (`LangChain.Message`, `ContentPart`, `ToolCall`, `ToolResult`), tool execution (`LLMChain.execute_tool_calls/3` + `LangChain.Function.execute/3`), the API-log payload format, and the test seam (`Mimic.stub_with(LangChain.Chains.LLMChain, ...)`).

Two specific bugs we want to close:

1. **Thinking tokens are dropped before they reach Nest.** LangChain's `ChatOpenAI.do_process_response/2` for the streaming-delta clause (`deps/langchain/lib/chat_models/chat_open_ai.ex:1149-1191`) does not extract `reasoning_content` from the OpenAI-compatible SSE chunk. DeepSeek, Qwen, and llama.cpp's server all emit `reasoning_content` for thinking models. LangChain silently discards it. Nest's `extract_thinking/1`, `part_to_segment(%{type: :thinking})`, `append_thinking`, and the React `ThinkingSection` UI are all correctly wired — but the data never makes it past the parser.
2. **Streaming is fake.** Nest runs `LLMChain.run/1` in a blocking task, then chunks the final aggregated response into 5-character pieces (`agent.ex:1308 chunk_content/2`) and broadcasts each as a `chat:delta`. The model is fast; the user sees a delayed, jerky stream. A direct Req SSE client can broadcast deltas as the model emits them.

Cutting LangChain also makes the dep tree smaller: `langchain ~> 0.8` pulls in `dotenvy`, `gettext`, `ecto` (LangChain uses Ecto.Changeset for its schemas), and optional `nx` / `abacus` / `mint_web_socket` / `nimble_parsec` / `req_llm`. None of those are needed for what Nest actually uses.

## Scope

The cutover is large because five things live behind the LangChain seam:

- Wire format (HTTP/SSE parsing for OpenAI + Anthropic)
- Message DTOs (the transient LangChain types used as wire shapes)
- Tool execution (LangChain.Function + LLMChain.execute_tool_calls)
- API log payload format (the shape `ChatOpenAI.for_api/3` returns)
- Test seam (Mimic stubbing of `LangChain.Chains.LLMChain`)

Nest's own message schema (`lib/nest/messages/{system,user,assistant,tool,tool_call,tool_result}.ex`) and the streaming accumulator (`lib/nest/messages/streaming.ex`) are already LangChain-free and stay. The LangChain types are only used as transient DTOs in two functions: `convert_to_langchain_messages/1` (inbound) and `build_api_response/1` (outbound). The agent's persistence and PubSub paths don't touch LangChain.

## Phases

Each phase is a self-contained, reviewable change with a clean rollback boundary.

### Phase 0 — Define the boundary

A behavior module the agent calls into, plus a mock that tests the boundary without yet touching any wire code.

- New `lib/nest/llm/client.ex` (behavior, event types)
- New `lib/nest/llm/run_request.ex` (request struct)
- New `lib/nest/llm/run_response.ex` (response struct)
- New `lib/nest/llm/tool.ex` (Nest tool spec, replaces `LangChain.Function`)
- New `lib/nest/llm/tool_result.ex` (LLM-layer tool result, minimal)
- New `lib/nest/llm/mock_client.ex` (test mock mirroring the boundary)
- New test files for the above
- No changes to `lib/nest/chat_model.ex`, `lib/nest/agents/agent.ex`, `lib/nest/tools.ex`, or `test/support/lang_chain_mock.ex`

### Phase 1 — Real Req streaming for the OpenAI path

Implement `Nest.LLM.OpenAIClient` end-to-end, drive the streaming accumulator from real canonical events, replace post-hoc chunking with real-time deltas. Wire the agent through the new behavior for the OpenAI path; keep the LangChain path for Anthropic.

### Phase 2 — Anthropic

Implement `Nest.LLM.AnthropicClient` for the `/v1/messages` named-event SSE format. Capture the thinking `signature` for echo-back. Drop the LangChain dep from the compile graph entirely (no source-of-truth users left).

### Phase 3 — Tool execution shim

Replace `LLMChain.execute_tool_calls/3` with a Nest-native function in `Nest.LLM.Tools`. Move the `[Command executed successfully with no output]` placeholder from `ShellCmd` into the executor. Update `lib/nest/tools.ex` to produce `Nest.LLM.Tool` structs directly.

### Phase 4 — Port the test mock

`test/support/lang_chain_mock.ex` (358 lines) is replaced by `test/support/llm_mock.ex` that stubs `Nest.LLM.Client`. Update the ~30 test sites that do `Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)` to `Mimic.stub_with(Nest.LLM.Client, Nest.LLM.MockClient)`. Test bodies do not change.

### Phase 5 — Drop the dep

Remove `{:langchain, "~> 0.8.0"}` from `mix.exs`, run `mix deps.clean langchain`. Delete `test/support/lang_chain_mock.ex`. Delete the special-case `LangChain.Message.ContentPart` branch in `lib/nest/messages/message.ex:69-83` (defensive serializer that's dead once the new client emits wire-shaped maps). Update `lib/nest/test/req_null_adapter.ex:47` error message.

### Phase 6 — Real-time thinking

Free with the Phase 1 plumbing. No new code required — the existing `handle_info({:delta_received, ...})` routes text, thinking, and tool-arg deltas to the right accumulator functions. The `ThinkingSection` UI now grows live as the model thinks. The persisted assistant message's `thinking` field is populated for OpenAI paths that emit `reasoning_content` (Qwen, DeepSeek, llama.cpp, OpenRouter). For Anthropic, also populate `thinking_signature` on the assistant message's `metadata` so it can be echoed back.

## What stays the same (intentionally)

- `Nest.Messages.{System,User,Assistant,Tool,ToolCall,ToolResult}` — the canonical in-memory schema.
- `lib/nest/messages/streaming.ex` — the accumulator already speaks `text | thinking | tool_use` segments with no LangChain types. We just feed it real deltas instead of post-hoc reconstructed ones.
- The PubSub event contract (`chat:message`, `chat:delta`, `chat:error`, `chat:status`, `chat:sync`).
- The React store and components (`MessageContent.jsx:162`, `ChatPage.jsx:156-205`).
- The 5-iteration tool-call cap (logic moves from `LLMChain.execute_tool_calls(..., max_iterations: 5)` to a Nest-side counter).
- The TOML provider config (`protocol`, `base-url`, `api-key`, `timeout`, `auto-models`, `models`, `tags`).
- `DotConfig.resolve_api_key/1` and `discover_model/1` paths.

## What changes at the API surface

Nothing externally. The Phoenix channel protocol, the TOML config, and the HTTP error semantics for users are all unchanged.

## Detailed Phase 0 design

### Canonical event stream

The boundary yields a flat list of canonical events from a streaming Enumerable. Each provider's wire format is private; both clients translate into the same vocabulary.

```elixir
@type event ::
        {:text, String.t()}
      | {:thinking, String.t()}
      | {:thinking_signature, String.t()}
      | {:refusal, String.t()}
      | {:tool_call_start, %{id: String.t(), name: String.t()}}
      | {:tool_call_delta, %{id: String.t(), arguments_delta: String.t()}}
      | {:usage, %{input_tokens: integer(), output_tokens: integer()}}
      | {:finish_reason, String.t() | nil}
      | {:error, term()}
      | {:done, %{response: RunResponse.t()}}
```

Design choices:

- `{:thinking_signature, sig}` is Anthropic-specific. Other clients emit nothing for it. The presence of a signature in a `RunResponse` means the assistant turn included a thinking block that must be echoed back on subsequent requests.
- Tool calls are accumulated by the consumer across `:tool_call_start` and `:tool_call_delta` events. They become "complete" when `:done` arrives carrying the parsed `RunResponse.tool_calls` list. No separate `:tool_call_complete` event.
- `{:usage, ...}` is only emitted when the client requested it (OpenAI: `stream_options.include_usage: true`) or when the provider includes it unconditionally (Anthropic: `message_delta.usage`).
- `{:error, reason}` is the in-band error signal. `{:done, ...}` always carries a `RunResponse`; errors before any text was produced are returned as `{:error, reason}` from the `run/2` callback itself.

### `Nest.LLM.RunRequest`

```elixir
defstruct messages: [], tools: [], model: nil, tool_choice: :auto,
          temperature: nil, max_tokens: nil, top_p: nil,
          stream: true, metadata: nil
```

`messages` is `[Nest.Messages.Message.t()]` (the tagged-tuple form, not LangChain). `tools` is `[Nest.LLM.Tool.t()]`. `metadata` is a free-form map for provider-specific knobs (e.g. `reasoning_field: "reasoning_content"`, `parallel_tool_calls: true`).

### `Nest.LLM.RunResponse`

```elixir
defstruct text: nil, thinking: nil, thinking_signature: nil,
          tool_calls: [], refusal: nil, usage: nil,
          stop_reason: nil, model: nil, metadata: nil
```

`tool_calls` is `[Nest.Messages.ToolCall.t()]` — uses the existing canonical struct, no parallel definition. `usage` is a plain map with `:prompt_tokens`, `:completion_tokens`, `:total_tokens`, `:reasoning_tokens` keys.

### `Nest.LLM.Client` behavior

```elixir
@callback run(RunRequest.t(), keyword()) ::
            {:ok, Enumerable.t(event())} | {:error, term()}

@callback format_request_payload(RunRequest.t(), keyword()) :: map()
```

`run/2` is the streaming entry point. The returned Enumerable is consumed by the agent's chat task via `Enum.reduce` or a custom loop. The Enumerable is finite and ends with exactly one `:done` event (or, on in-band error, an `:error` event followed by `:done`).

`format_request_payload/2` is what the agent calls to populate the `api_logs` request entry. It returns the wire-format request map (the same shape `ChatOpenAI.for_api/3` used to return). Different per client because the wire shape differs.

The keyword option list is a free-form hook for the caller to pass provider-specific things without polluting the request struct (e.g. `system_prompt: "..."` for clients that need it as a top-level field rather than a `:system` message).

### `Nest.LLM.Tool`

```elixir
defstruct name: nil, description: nil, parameters_schema: nil, function: nil
```

A direct replacement for `LangChain.Function`. The `function` field is a 2-arity anonymous function `(args :: map(), context :: map()) :: {:ok, String.t()} | {:error, String.t()}`. `parameters_schema` is a JSON Schema map.

### `Nest.LLM.ToolResult`

```elixir
defstruct tool_call_id: nil, name: nil, content: nil, is_error: false
```

The LLM-layer tool result. Minimal: just what the executor returns. The agent decorates with `arguments` (looked up by call_id) and wraps in a `Nest.Messages.ToolResult` when persisting.

### `Nest.LLM.MockClient`

Mirrors what the real client will do:

- Process-safe state via an `Agent` named `Nest.LLM.MockClient.Agent` (or similar).
- Scripted API: `set_response/1`, `set_tool_response/1`, `set_error/1`, `set_stream_events/1`, `clear/0`.
- `run/2` returns `{:ok, Stream}` where the Stream is an Enumerable that yields the canned canonical events one by one, ending with `{:done, %{response: ...}}`.
- `format_request_payload/2` returns a stable map shape (whatever the OpenAI wire format looks like — Phase 0 will use the natural OpenAI-compat shape; tests can assert against it without yet asserting against a real LLM response).

### Phase 0 tests

- `test/nest/llm/run_request_test.exs` — struct defaults, validation helpers if any.
- `test/nest/llm/run_response_test.exs` — struct defaults, `:done` event shape.
- `test/nest/llm/mock_client_test.exs` — scripted response surface, event ordering, multi-step scripts, error injection.
- `test/nest/llm/client_test.exs` — behavior compliance check (MockClient implements the behavior correctly).

No existing test changes. No app code changes. `mix precommit` must stay green.

## Open questions

1. **Phase 1 boundary in agent.ex.** The agent currently has `chain.llm` (a `LangChain.ChatModels.ChatOpenAI` struct) and `chain.messages` (LangChain types). Two options:
   - (a) Replace `chain` with a `%Nest.LLM.RunRequest{}` and pass it to `Client.run/2`. Cleanest, but touches every LangChain usage in `agent.ex` (line 663, 875, 878, 881, 887, 1000, 1124, etc.).
   - (b) Keep the `chain` shape, just replace the call to `LLMChain.run` with `Client.run/2` taking a request built at call time. Less intrusive, leaves a hybrid that gets cleaned up in Phase 5.
   Recommendation: (a) for Phase 1 — it makes the agent readable and the diff easier to review than a half-converted chain.
2. **Anthropic extended thinking.** The `thinking_signature` echo-back is a Phase 2 deliverable. Without it, Claude's extended thinking works for single-turn but breaks on multi-turn. If Anthropic isn't a near-term priority we could ship without it and add later; otherwise Phase 2 needs to wire `Assistant.metadata["thinking_signature"]` through the conversion functions.
3. **Provider-specific config keys.** Some OpenAI-compatible proxies want `parallel_tool_calls: false` or a custom `reasoning_field` name. Recommend adding optional `provider_opts :: map()` to `DotConfig.Provider` rather than a flag per behavior. Phase 0 doesn't need this; Phase 1 adds the field.
4. **Mock client test seam.** Should `MockClient` be wired via `Mimic.stub_with` (current pattern) or via a behavior-implementing module that's injected at agent startup? The current pattern is fine; stick with it.
5. **Backwards compatibility during the migration.** Several sites use `Mimic.stub(LangChain.Chains.LLMChain, :run, fn _ -> ... end)` directly. Phase 4 needs to convert these to `Mimic.stub_with(Nest.LLM.Client, Nest.LLM.MockClient)` and use `set_error/1` instead. The test bodies stay the same; only the stub surface changes.
