# Fix real API calls (kraken / llama.cpp)

## Goal
Get `scripts/test-kraken.exs` working end-to-end against the live
`http://kraken:8080/v1` llama.cpp server so we can confirm the
Nest-native LLM clients actually drive a real provider, not just
the `MockClient`.

## What was wrong (this turn)

### Bug 1: Async body is process-bound (fixed)
`%Req.Response.Async{}` is enumerable, but its `reduce/3`
implementation (in `deps/req/lib/req/response_async.ex:50`) does
`if async.pid != self(), do: raise "expected to read body chunk in
the process which made the request, got: <self>"`. The original
`build_event_stream/1` design in both `OpenAIClient` and
`AnthropicClient` called `Req.post` from the parent (the agent's
Task) and then `spawn_link`'d a child to drain the body. The
child could not iterate the body, so it raised
`RuntimeError: expected to read body chunk in the process
#PID<0.95.0> which made the request, got: #PID<0.504.0>`. The
child's `catch` block sent a synthetic `stream_terminated` chunk
to the parent; the script then saw an empty response.

The original `Enum.each` clauses inside the spawn_link were also
wrong (see Bug 2), but they were never reached because the
`raise` in `response_async.ex:50` happened first. `MockClient`
doesn't go through `Req` so unit tests never caught either bug.

**Fix**: move the `Req.post` call AND the body iteration into a
single worker process spawned by `run/2`. The worker is its own
`Req.post` caller, so the body is bound to the worker and it can
drain it. It forwards each chunk as `{:req_chunk, _}` (and
`:req_done` at the end) to the parent. `run/2` always returns
`{:ok, stream}`. Non-200 status, connection failure, and
mid-stream errors all become synthetic SSE chunks in the stream.

### Bug 2: Async body yields raw data, not tagged tuples (fixed)
The `Enum.each` callback in the spawn_link matched on
`{:data, chunk}` / `{:trailers, _}` / `:done`. But the
`response_async.ex` impl is:

```elixir
{:ok, [data: data]} ->
  fun.(data, acc)   # raw bytes, NOT a tagged tuple
```

The `[:data | :trailers | :done]` framing is consumed inside
`response_async.ex`; the user's reducer only ever sees raw chunk
bytes. So `Enum.each(body, fn {:data, c} -> ... end)` raised
`FunctionClauseError` once Bug 1 was unblocked. Replaced with
`Enum.each(body, fn chunk -> send(parent, {:req_chunk, chunk}) end)`
followed by `send(parent, :req_done)`.

### Behavior change: `run/2` now always returns `{:ok, stream}`
Previously `run/2` could return `{:error, _}` for connection
refused / non-2xx status. With the worker handling all cases and
synthesizing SSE chunks, `run/2` always returns `{:ok, stream}`.
The error surfaces as a single `{:error, _}` event inside the
stream (followed by `:done`), which the agent's
`consume_new_stream/4` reducer already captures into the
`error` field of its accumulator and routes to
`handle_failed_response/3`.

## What changed

- `lib/nest/llm/openai_client.ex` — `run/2` now spawns
  `http_worker/6`; old `build_event_stream/1` (which took the
  body) replaced with a parameterless `build_event_stream/0`
  (mailbox receive loop). `send_chunk/4` helper formats synthetic
  error chunks.
- `lib/nest/llm/anthropic_client.ex` — same refactor. Deleted
  the now-redundant `drain_async_body/1` (was duplicating the
  worker logic; the worker absorbs it).
- `lib/nest/llm/client.ex` — `@callback run/2` spec narrowed to
  `{:ok, Enumerable.t(event())}` (was `| {:error, term()}`).
  Docstring rewritten to say errors always arrive inside the
  stream.
- `lib/nest/llm/mock_client.ex` — `run/2` no longer short-circuits
  on `{:error, _}`; builds a stream yielding `{:error, reason}`
  followed by `:done`. Added `error_stream/1`.
- `lib/nest/agents/agent.ex` — deleted the dead
  `{:error, _} -> handle_run_error(...)` branch in
  `run_with_new_client/2` and the now-unused `handle_run_error/3`.
  `run_with_new_client/2` now pattern-matches `{:ok, stream}`.
- `scripts/test-{kraken,pegasus,mstudio}.exs` — dropped the dead
  `{:error, _}` branches + removed the `IO.inspect` debug I had
  added in the kraken script.
- `test/nest/llm/mock_client_test.exs` — `set_error/1` test
  rewritten to assert the stream yields `[{:error, reason},
  {:done, _}]` instead of `{:error, _}`.
- `test/nest_web/channels/agent_channel_test.exs` — both
  `chat:error event` tests now stub `OpenAIClient.run/2` to return
  `{:ok, Stream.map([{:error, "..."}], & &1)}` instead of
  `{:error, "..."}`.

## Validation
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (640 mods/funs, 0 issues)
- `mix compile --warnings-as-errors` ✓
- `mix test` ✓ (333 tests, 0 failures)

## What works now (kraken script, first run after the refactor)
The streaming fix landed. The Qwen3.6-35B-A3B reasoning model
responded with a `tool_call` for `roll(notation="3d6")` — the
script invoked the local dice function (result:
`{"count":3,"total":5,"notation":"3d6","sides":6,"rolls":[1,1,3]}`)
and tried to re-send the conversation. **It then crashed in
the second iteration of the tool loop with:**

```
** (FunctionClauseError) no function clause matching in
   anonymous fn/1 in Nest.LLM.OpenAIClient.message_to_wire/1
   %Nest.LLM.ToolResult{
     tool_call_id: "0X8IXzoTVFjxCo33DNprtzQ0LL3zJvMW",
     name: "roll",
     content: "{\"count\":3,...}",
     is_error: false
   }
```

## Open bug (next)

The script's `do_run_with_tool_loop/5` (and the agent's
equivalent) re-sends the conversation with the tool results
appended. The script appends them as:

```elixir
results = Tools.execute(tools, response.tool_calls, %{tool_call_id: nil})
tool_message = {:tool, %Tool{index: next_index, tool_results: results}}
```

`Tools.execute/3` returns `Nest.LLM.ToolResult` structs
(`lib/nest/llm/tool_result.ex` — the raw struct that wraps the
function call's `{:ok, content}` / `{:error, content}` output).
`OpenAIClient.message_to_wire({:tool, %Tool{tool_results: results}})`
maps them via `Enum.map(results, fn %ToolResult{...} -> ...
end)` — but the `ToolResult` alias on L24 is
`alias Nest.Messages.ToolResult`, NOT
`alias Nest.LLM.ToolResult`. So the pattern match fails.

Two things to reconcile:

1. The `Nest.LLM.ToolResult` struct has `name` (the function
   name); the `Nest.Messages.ToolResult` struct does not. The
   wire format (`%{"role" => "tool", "tool_call_id" => id,
   "content" => content}`) doesn't carry `name`, so
   `Nest.Messages.ToolResult` is the right shape for
   `message_to_wire/1`. The conversion from
   `Nest.LLM.ToolResult` -> `Nest.Messages.ToolResult` should
   happen at the boundary (the agent's `build_tool_pair/3`
   function probably already does this; the script doesn't).

2. The script's `do_run_with_tool_loop/5` is a simplified
   version of the agent's tool loop. It needs to wrap the
   `Nest.LLM.ToolResult` list in `Nest.Messages.ToolResult`
   structs before stuffing it into `%Tool{}`. Or — the cleaner
   fix — make `Tools.execute/3` return `Nest.Messages.ToolResult`
   structs directly (they're closer to the wire format anyway),
   and reserve `Nest.LLM.ToolResult` for the function-call
   boundary that wraps a single function call's return.

## Plan
- Decide which struct `Tools.execute/3` should return.
  - Option A: `Nest.Messages.ToolResult` directly (cleaner, the
    agent and script both need this shape).
  - Option B: keep `Nest.LLM.ToolResult` and have callers
    convert. (More indirection, but the LLM-side struct can
    carry the function name which is useful for logging.)
- Make the chosen change, fix the script, re-run kraken, expect
  to see a final `text` response with the rolled stats.
- Once kraken works end-to-end, audit the same code path in the
  agent (it's the same shape; likely already correct since
  `build_tool_pair/3` lives in `lib/nest/agents/agent.ex`).

---

## Fix 2: Non-200 response body is `%Req.Response.Async{}` (fixed)

### Bug 3: Non-200 responses with `into: :self` have async bodies
When `Req.post` is called with `into: :self`, the response body is
**always** `%Req.Response.Async{}`, regardless of status code. The
error handler in `http_worker/6` matched on
`{:ok, %Req.Response{status: status, body: body}}` and passed `body`
directly to `send_chunk/4`, which tried to JSON-encode it. Since
`%Req.Response.Async{}` doesn't implement `Jason.Encoder`, this
raised `Protocol.UndefinedError`.

This manifested when the llama.cpp server rejected a request
(exceeded context size) with a non-200 status — the worker crashed
trying to encode the async body instead of draining it and
surfacing the error message.

**Fix**: Added a specific clause for non-200 responses with async
bodies in both `OpenAIClient` and `AnthropicClient`. The clause
drains the async body in the worker process (allowed since the
worker called `Req.post`), collects the chunks into a binary, and
passes that to `send_chunk/4`. The error message is now properly
surfaced as a synthetic SSE chunk.

### What changed
- `lib/nest/llm/openai_client.ex` — Added clause for
  `%Req.Response{status: status, body: %Req.Response.Async{}}`
  that drains the body and sends it as an error chunk. Added
  public `consume_sse_from_mailbox/0` for testability.
- `lib/nest/llm/anthropic_client.ex` — Same clause added.
- `test/nest/llm/openai_client_test.exs` — Added error handling
  tests for synthetic error chunks.
- `test/nest/llm/anthropic_client_test.exs` — Same tests added.

### Validation
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (641 mods/funs, 0 issues)
- `mix compile --warnings-as-errors` ✓
- `mix test` ✓ (337 tests, 0 failures)
- `mix assets.test` ✓ (330 tests passed)
- `mix assets.check` ✓

---

## Fix 3: "Generating response" indicator lost after tool result (fixed)

### Bug 4: Frontend infers streaming state from `partial !== null`
The ChatPage determined whether the LLM was "generating" by checking
if `partial !== null`. This broke during tool-call loops because:

1. User sends message → `partial` is set, `waitingForResponse = true`
2. First delta of tool-calling response → `partial` updated, `waitingForResponse = false`
3. `chat:message` (assistant with toolCalls) → `addChatMessage` clears `partial = null`
4. `chat:message` (tool result) → `partial` stays null
5. LLM is called again with tool results → ... time passes with no indicator ...
6. First delta of next response → `partial` is set again

Between steps 3 and 6, the indicator showed "Ready" even though the
agent was actively working.

### Root cause
The frontend had no way to know the agent's actual state. The Agent
GenServer tracked `:idle | :streaming | :executing_tools` internally
but never broadcast these transitions. The frontend had to guess based
on the presence of `partial`/`streaming` objects, which were cleared
when intermediate tool messages arrived.

### Fix
Made the backend the source of truth for the generating indicator:

1. **Backend broadcasts status changes**: Added `broadcast_status/2`
   helper in `agent.ex` that sends `{:chat_status, %{status: ...}}`
   via PubSub whenever the agent's status changes.

2. **Channel pushes status to client**: Added `handle_info({:chat_status, ...})`
   in `agent_channel.ex` that pushes `"chat:status"` events to the client.

3. **Frontend stores agentState**: Added `setAgentState` action to the
   store. Updated `setAgentConnected` to store the initial `agentState`
   from the init payload's `status` field.

4. **Frontend listens for status events**: Added `chat:status` listener
   in `channels.js` that calls `setAgentState`.

5. **ChatPage uses agentState**: Replaced `streaming = partial !== null`
   with `streaming = agentState === "streaming"` and added
   `executingTools = agentState === "executing_tools"`. Updated the
   typing indicator to show "Executing tools" when appropriate.

### What changed
- `lib/nest/agents/agent.ex` — Added `broadcast_status/2` helper.
  Called it at 5 status transition points: `:streaming` (chat start),
  `:idle` (error), `:executing_tools` (tool calls received),
  `:streaming` (tool results received), `:idle` (response complete).
- `lib/nest_web/channels/agent_channel.ex` — Added `handle_info` for
  `{:chat_status, ...}` that pushes to client.
- `assets/js/store/index.js` — Added `setAgentState` action. Updated
  `setAgentConnected` to store `agentState` from payload.
- `assets/js/channels.js` — Added `chat:status` event listener.
- `assets/js/pages/ChatPage.jsx` — Uses `agentState` instead of
  inferring from `partial`. Shows "Executing tools" indicator.
- `test/nest/agents/agent_test.exs` — Added tests for status broadcasts.
- `assets/js/store/index.test.js` — Added tests for `setAgentState`.
- `assets/js/channels.test.js` — Added test for `chat:status` event.

### Validation
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (643 mods/funs, 0 issues)
- `mix compile --warnings-as-errors` ✓
- `mix test` ✓ (339 tests, 0 failures)
- `mix assets.test` ✓ (336 tests passed)
- `mix assets.check` ✓

---

## Fix 4: "Max tool iterations reached" displayed as error (fixed)

### Problem
When the agent hit the max tool iteration limit, it was displayed as a
connection error (red banner with "Connection failed" and Retry button).
This was wrong because:
1. It's not a connection error — it's a normal operational limit
2. The user was stuck and couldn't continue chatting
3. The error styling suggested something broke that needed fixing

### Root cause
The max iterations path called `handle_failed_response/3`, which:
1. Broadcast `{:chat_error, ...}` — frontend treated as connection failure
2. Sent `{:llm_error, ...}` to agent — created a fake assistant message
3. Set agent status to `:idle`

The frontend's `chat:error` handler:
1. Called `setAgentError` — set `status: "error"`
2. Cleared `partial` — stopped showing "Generating response"
3. Disabled input because `status !== "connected"`

### Fix
Added a new `chat:notification` event type for system-level notifications
that aren't errors. The max iterations case now:
1. Broadcasts `{:chat_notification, %{type: "max_iterations", ...}}`
2. Broadcasts `{:chat_status, %{status: "idle"}}` (agent returns to ready)
3. Does NOT create a fake assistant message
4. Does NOT set error state

The frontend:
1. Stores notification in `cache.notification`
2. Shows amber/yellow banner with close button
3. Keeps input enabled (status remains "connected")
4. Clears notification when user sends next message

### What changed
- `lib/nest/agents/agent.ex` — Modified `run_with_new_client` when
  `max_iterations: 0` to broadcast notification instead of calling
  `handle_failed_response`. Added `broadcast_notification/2` helper.
- `lib/nest_web/channels/agent_channel.ex` — Added `handle_info` for
  `{:chat_notification, ...}` that pushes to client.
- `assets/js/store/index.js` — Added `notification` to cache state.
  Added `setNotification` and `clearNotification` actions. Modified
  `addUserMessage` to clear notification.
- `assets/js/channels.js` — Added `chat:notification` event listener.
- `assets/js/pages/ChatPage.jsx` — Added `NotificationBanner` component
  with amber styling and close button. Rendered after `StatusBanner`.
- `test/nest/agents/agent_test.exs` — Added test for notification broadcast.
- `assets/js/store/index.test.js` — Added tests for notification actions.
- `assets/js/channels.test.js` — Added test for `chat:notification` event.

### Validation
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (645 mods/funs, 0 issues)
- `mix compile --warnings-as-errors` ✓
- `mix test` ✓ (340 tests, 0 failures)
- `mix assets.test` ✓ (343 tests passed)
- `mix assets.check` ✓

---

## Fix 5: Max iterations produces final response instead of stopping (fixed)

### Problem
When the agent hit the max tool iteration limit, it would:
1. Execute the tools and broadcast the results
2. Decrement max_iterations to 0
3. Stop immediately without making a final LLM call
4. Show a notification banner

This meant the LLM never got to see the tool results and produce a summary. The conversation would just... stop after tool execution.

### Root cause
The `run_with_new_client/2` function had a special case for `max_iterations: 0` that would broadcast a notification and return immediately, without making another LLM call. The tool results existed in the message history, but the LLM never got to process them.

### Fix
Changed the `max_iterations: 0` case to make **one final LLM call with `tools: nil`** instead of stopping:

```elixir
defp run_with_new_client(%RunContext{} = ctx, %RunState{max_iterations: 0} = state) do
  Logger.warning(
    "Agent #{ctx.agent_id} reached max tool iterations, making final call without tools"
  )

  broadcast_notification(ctx.agent_id, %{
    type: "max_iterations",
    message: "Max tool iterations reached"
  })

  # Make one final LLM call without tools so the LLM can see the tool results
  # and produce a final text response
  final_ctx = %{ctx | tools: nil}

  state = broadcast_request_log(final_ctx, state)
  {:ok, stream} = run_request(final_ctx)
  handle_new_stream(final_ctx, state, stream)
end
```

**Why this works:**
- `tools: nil` means the LLM can't request more tools — it must produce a text response
- The message history already contains the tool results, so the LLM has full context
- `handle_new_stream` will see no tool calls in the response and go through `send_final_assistant` (the normal terminal path)
- The notification banner still appears (amber, with close button) so the user knows the limit was hit
- The agent goes idle naturally after the final response
- No risk of infinite loop: with `tools: nil`, the LLM physically cannot return tool calls

### MockClient updates
The MockClient needed updates to support this:

1. **`tools_to_wire/1`** — Added clause for `nil` tools (was only handling `[]`)
2. **`run/2`** — Now passes `request.tools` to `take_script/1`
3. **`take_script/1`** — Accepts tools parameter and passes to `take_head/2`
4. **`take_head/2`** — When tools is nil, skips queued tool responses and returns the next non-tool response. This ensures the final call (with tools: nil) gets the text response, not a queued tool response.

### What changed
- `lib/nest/agents/agent.ex` — Modified `run_with_new_client/2` when `max_iterations: 0` to make final call without tools instead of stopping.
- `lib/nest/llm/mock_client.ex` — Updated to handle `nil` tools and skip tool responses when tools is nil.
- `test/nest/agents/agent_test.exs` — Updated test to verify final assistant response is produced.

### Validation
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (647 mods/funs, 0 issues)
- `mix compile --warnings-as-errors` ✓
- `mix test` ✓ (340 tests, 0 failures)
- `mix assets.test` ✓ (343 tests passed)
- `mix assets.check` ✓

---

## Fix 6: Max iterations final call sets tool_choice to :none (fixed)

### Problem
When the agent hit max tool iterations and made the final LLM call with `tools: nil`, the request still included `tool_choice: "auto"` (the default). Some models would interpret this as "you can still generate raw XML-style function call syntax even without tools being explicitly defined," resulting in the next assistant message containing raw tool call XML instead of a proper text response.

### Root cause
The `RunContext` struct didn't have a `tool_choice` field, so `build_run_request/1` couldn't pass it through to the `RunRequest`. The `RunRequest` defaulted to `tool_choice: :auto`, which got serialized to `tool_choice: "auto"` in the wire format.

When max iterations was hit, we set `tools: nil` but didn't override `tool_choice`, so the final call had:
- `tools: nil` (no tools available)
- `tool_choice: "auto"` (you decide whether to call tools)

This ambiguity caused some models to generate raw tool call syntax.

### Fix
Added `tool_choice` to `RunContext` and explicitly set it to `:none` in the final call:

1. **Added `tool_choice: :auto` to `RunContext` struct** — Matches the `RunRequest` default
2. **Updated `build_run_request/1`** — Now uses `ctx.tool_choice` instead of relying on the default
3. **Updated max iterations case** — Sets both `tools: nil` and `tool_choice: :none`

```elixir
defp run_with_new_client(%RunContext{} = ctx, %RunState{max_iterations: 0} = state) do
  Logger.warning(
    "Agent #{ctx.agent_id} reached max tool iterations, making final call without tools"
  )

  broadcast_notification(ctx.agent_id, %{
    type: "max_iterations",
    message: "Max tool iterations reached"
  })

  # Make one final LLM call with tools disabled (both tools and tool_choice)
  # so the LLM sees the tool results and produces a text response
  final_ctx = %{ctx | tools: nil, tool_choice: :none}

  state = broadcast_request_log(final_ctx, state)
  {:ok, stream} = run_request(final_ctx)
  handle_new_stream(final_ctx, state, stream)
end
```

**Why this works:**
- `tool_choice: :none` explicitly tells the model "you cannot call any tools, period"
- Combined with `tools: nil`, there's no ambiguity — the model must generate text
- The `normalize_tool_choice/1` function in both OpenAI and Anthropic clients already supports `:none`
- This is the standard way to force a text-only response in the OpenAI API

### What changed
- `lib/nest/agents/agent.ex` — Added `tool_choice: :auto` to `RunContext` struct. Updated `build_run_request/1` to use `ctx.tool_choice`. Updated max iterations case to set `tool_choice: :none`.
- `test/nest/agents/agent_test.exs` — Updated test to verify the final call's wire format includes `tool_choice: "none"` and `tools: nil`.

### Validation
- `mix format --check-formatted` ✓
- `mix credo --strict` ✓ (647 mods/funs, 0 issues)
- `mix compile --warnings-as-errors` ✓
- `mix test` ✓ (340 tests, 0 failures)
- `mix assets.test` ✓ (343 tests passed)
- `mix assets.check` ✓
