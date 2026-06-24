# Agent state refactor: split iteration authority from conversation storage

## Overview

Split the current `Nest.Agents.Agent` GenServer's responsibilities. Today it owns both the **conversation storage** (the messages list, the index allocator, the identity state) and acts as the **broadcast router**. The `Nest.Agents.Agent.LLMRunner` Task that drives the iteration is a separate process that has its own parallel counter for message indices, leading to a dual-counter bug class that has already bitten us once (the tool-call budget warning that gets overwritten by the next streaming response).

The new design adds a third process: `Nest.Agents.Agent.ChatTurn`, a GenServer dedicated to a single chat turn. The Agent GenServer stays the storage layer. The ChatTurn is the iteration state machine. The HTTP and tool-execution workers are stateless I/O helpers. The Agent is the single source of truth for conversation state; the ChatTurn is the coordinator that drives one turn's iteration.

## Why we have to do this

The current design has the LLMRunner maintaining its own `RunState.message_index` (seeded from the Agent's `streaming_acc.index` and bumped by 2 for each tool pair). The Agent's `system_reminder_received/2` handler independently picks the next free slot from `ChatState.next_message_index`. The two counters are supposed to stay in lockstep but they can drift — when a side-channel message like the budget warning fires, the LLMRunner's `+2` math doesn't account for the slot the Agent just handed out to the reminder. The reminder and the next response end up at the same index, and the JS `addChatMessage` merge logic silently overwrites the reminder with the response.

Every contributor who adds a side-channel message to the conversation has to remember to also update the LLMRunner's `+2` math. The bug class is closed by construction only when there's **one writer** for the index. That writer should be the Agent, and the Agent's `next_message_index` should be the only counter in the system.

But making the Agent the only writer also means the Agent needs to be the one stamping the index on every message append. The LLMRunner, which currently builds messages with explicit indices, has to stop doing that. The cleanest way to enforce this is to make the LLMRunner a stateless HTTP client that emits events to a new GenServer whose job is to drive the iteration and ask the Agent to append messages.

The ChatTurn GenServer is that new GenServer. It owns the iteration state machine, queries the Agent for conversation state when it needs it, and tells the Agent to append messages when it has new ones. The Agent stamps the indices; the ChatTurn never knows what they are.

## The new design

### Process topology

```
Nest.Agents.Agent (GenServer, permanent, per agent)
  ↳ owns: messages list, next_message_index, identity, llm_metrics, history
  ↳ is: the storage layer; the single source of truth for conversation state
  ↳ spawns and supervises: ChatTurn children, one per turn
  ↳ broadcasts to the UI on behalf of the active ChatTurn

Nest.Agents.Agent.ChatTurn (GenServer, per turn, alive during one chat turn)
  ↳ owns: iteration state (current round, max_iterations, streaming_acc, active worker pid)
  ↳ is: the iteration state machine
  ↳ queries the Agent for: messages, identity state
  ↳ tells the Agent to: append messages, broadcast events
  ↳ spawns and supervises: HTTP worker (per LLM call) and tool worker (per tool batch)

Nest.LLM.HttpWorker (ephemeral, per LLM call)
  ↳ owns: nothing
  ↳ makes the HTTP call, consumes the SSE stream
  ↳ emits: deltas, response_done (or error) to the ChatTurn
  ↳ exits when the stream is done, on error, or on stop

Nest.Agents.Agent.ToolLoop.Executor (ephemeral, per tool batch)
  ↳ owns: nothing
  ↳ runs the tools
  ↳ emits: tool_results to the ChatTurn
  ↳ exits when the tools are done
```

At any moment, the Agent GenServer is alive. While a turn is in flight, the ChatTurn GenServer is also alive. During an LLM streaming response, the HTTP worker is alive. During tool execution, the tool worker is alive. Never both an HTTP worker and a tool worker at the same time. Between turns, only the Agent is alive.

The Agent and the ChatTurn are the only two long-lived processes for a chat. The HTTP and tool workers come and go within a turn.

### The Agent GenServer's new shape

The Agent is still a thin message router, but its responsibilities are now:
- Own the conversation state (messages, next_message_index, history)
- Own the Agent identity state (model, vocation, client config, tools, llm_metrics)
- Receive UI events (`chat:message`, `chat:stop`) and route them to the active ChatTurn
- Receive append requests from the active ChatTurn, stamp the index, append to the messages list, broadcast to the UI
- Spawn and supervise ChatTurn children
- Handle ChatTurn lifecycle events (`:chat_idle`, `:chat_crashed`, `:chat_stopped`)

The Agent's `handle_call({:append_message, message}, ...)` is the **only** place that stamps `index` on a message. Every message — user, assistant, tool result, system reminder — flows through this handler. The dual counter is closed by construction.

```elixir
def handle_call({:append_message, message}, _from, state) do
  index = state.chat_state.next_message_index
  message = %{message | index: index}
  messages = state.chat_state.messages ++ [message]
  state = put_in(state.chat_state, %{state.chat_state |
    messages: messages,
    next_message_index: index + 1
  })
  Broadcasts.message(state.id, message)
  {:reply, :ok, state}
end
```

The Agent's `handle_call(:get_messages, ...)` returns the current messages list for the ChatTurn to build LLM requests. The Agent's `handle_info({:delta_received, ...}, ...)` re-broadcasts streaming deltas. The Agent's `handle_info({:stop_chat, from}, ...)` forwards to the active ChatTurn. The Agent's `handle_info({:chat_idle, ...}, ...)` and `handle_info({:chat_crashed, ...}, ...)` finalize the turn.

### The ChatTurn GenServer's shape

The ChatTurn is a dedicated state machine. It owns iteration state, not conversation state. Its lifecycle is one turn: spawned when a user message arrives, alive until the turn ends, then exits.

State (private to the ChatTurn):
```elixir
%{
  agent_pid: pid(),
  iteration: 0..max_iterations,
  max_iterations: non_neg_integer(),
  force_finalize: false,
  active_worker: pid() | nil,
  active_worker_kind: :http | :tools | nil,
  streaming_acc: Streaming.t() | nil,
  last_thinking: String.t() | nil,
  thinking_signature: String.t() | nil,
  api_log_sequences: %{},
  tool_calls_pending: [ToolCall.t()],
  cancelled: false
}
```

The ChatTurn is initialized with the current messages list (so it can build LLM requests without a round-trip to the Agent on every iteration). The state machine is driven by `handle_continue(:iterate, state)` for the iteration step, and `handle_info/2` for worker events, stop signals, and crashes.

The ChatTurn never assigns an index. Every message it builds has `index: nil`. The Agent stamps the index when the message is appended.

The ChatTurn never reads from the Agent's state except via a `GenServer.call(:get_messages)` at the start of each iteration. The Agent is the single source of truth.

### The HTTP worker

The HTTP worker is a stateless module that takes a `RunRequest`, makes the HTTP call, consumes the SSE stream, and emits canonical events to the ChatTurn via `send/2`. It exits when the stream is done, on error, or on stop. It has no message index awareness, no iteration state, no knowledge of the conversation.

The HTTP worker is the new `Nest.LLM.Runner` (renamed from `Nest.Agents.Agent.LLMRunner`). It implements one function: `request/2` that returns a `Stream.t()` of canonical events. The current `LLMRunner.RunState`, `LLMRunner.RunContext`, `build_tool_pair`, `maybe_inject_budget_warning`, `handle_max_iterations_with_tool_calls`, and `run_with_new_client_after_tool_calls` are all deleted — they were iteration state machine logic that belongs in the ChatTurn, not in the HTTP client.

### The tool worker

The tool worker is a stateless module that takes a list of `ToolCall`s, runs them via `Nest.Tokens.ToolLoop.execute/3`, and emits `tool_results` to the ChatTurn. It has no message index awareness, no iteration state.

The tool worker is a new module `Nest.Agents.Agent.ToolLoop.Executor` (or similar name) with a single `run/3` function. The current `Nest.Agents.Agent.ToolLoop.execute/3` (in `lib/nest/agents/agent/tool_loop.ex`) is the implementation; the new module is a thin wrapper that spawns the worker, runs the function, and sends the result back.

### The flow: one turn from start to finish

```
1.  UI: `chat:send` push to the channel
2.  AgentChannel: `Nest.Agents.Agent.handle_call({:chat, content, mode}, ...)`
3.  Agent: append user message via `handle_call({:append_message, user_msg}, ...)` (stamps index, broadcasts)
4.  Agent: spawn ChatTurn via `DynamicSupervisor.start_child(ChatTurn, args)` (args include the Agent's pid and the initial messages)
5.  ChatTurn: init/1 stores the initial messages and sets the state machine to :iterating
6.  ChatTurn: handle_continue(:iterate, state) starts the first iteration
7.  ChatTurn iteration step:
    a. Check budget (`iteration == max_iterations - 2` or `iteration == max_iterations - 1`). If budget is low, build a reminder message and call `Agent.handle_call({:append_message, reminder}, ...)`. The Agent stamps the index, appends, broadcasts.
    b. Get the current messages list: `GenServer.call(agent_pid, :get_messages)`. (For the first iteration, this is the initial messages from step 4. For subsequent iterations, the messages have grown by any new user/assistant/tool/reminder messages.)
    c. Build the LLM request from the messages list and the Agent's tools/caps.
    d. Spawn HTTP worker: `Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn -> HttpWorker.run(request, agent_id, self()) end)`. The HTTP worker's `self()` is the ChatTurn's pid.
    e. The HTTP worker runs, sending `{:delta_received, content, part_type}` and `{:thinking_delta, content}` events to the ChatTurn. The ChatTurn forwards them to the Agent for re-broadcast: `send(agent_pid, {:delta_received, content, part_type})`.
    f. The HTTP worker finishes with `{:response_done, response}` (or `{:error, ...}`).
    g. ChatTurn: receive the response. Append it via `Agent.handle_call({:append_message, response_with_nil_index}, ...)`. The Agent stamps the index.
    h. If the response has tool calls: spawn a tool worker with the tool calls. The tool worker sends back `{:tool_results, results}`. ChatTurn appends the results via `Agent.handle_call({:append_message, tool_result_with_nil_index}, ...)`. Then back to step 7a.
    i. If the response is final text (no tool calls): goto step 8.
8.  ChatTurn: `send(agent_pid, {:chat_idle, self()})`. Exits normally.
9.  Agent: `handle_info({:chat_idle, ...}, ...)` transitions to :idle, broadcasts status, clears the active ChatTurn reference.
```

### The contract between Agent and ChatTurn

**`GenServer.call` (synchronous, ChatTurn → Agent):**
- `{:get_messages}` — returns the current `chat_state.messages` list. Used by the ChatTurn to build LLM requests.
- `{:append_message, message}` — appends a message, stamps the index, broadcasts to the UI, returns `:ok`. This is the **only** path that mutates `chat_state.messages`.

**`send/2` (async, ChatTurn → Agent):**
- `{:delta_received, content, part_type}` — re-broadcast a streaming text delta. The Agent's `handle_info/2` forwards to `Broadcasts.delta_text` (or `Broadcasts.delta_thinking` for the thinking variant).
- `{:thinking_signature_received, sig}` — re-broadcast a thinking signature.
- `{:llm_usage, usage}` — merge usage into llm_metrics, broadcast status.
- `{:api_log, message_index, api_log}` — store the API log payload.
- `{:chat_idle, chat_turn_pid}` — the turn is done. Transition to :idle, broadcast, clear the active ChatTurn reference.
- `{:chat_crashed, exception, stacktrace}` — the ChatTurn crashed. Finalize any partial, broadcast `chat:error`, transition to :idle.
- `{:chat_stopped, chat_turn_pid}` — the user clicked Stop. Finalize any partial, transition to :idle.

**`send/2` (async, Agent → ChatTurn):**
- `{:stop_chat, from}` — the user clicked Stop. The ChatTurn kills the active worker, sets the `cancelled` flag, finalizes the partial, sends `{:chat_stopped, self()}` back to the Agent, exits.

This is the complete contract. Every state-mutating call is a `GenServer.call` so the ChatTurn knows the state was updated before proceeding. Every broadcast is a `send/2` because the ChatTurn doesn't need to wait for the broadcast to complete.

### The reminder is unremarkable

In the new design, the reminder is just another message the ChatTurn decides to append. The flow:

```elixir
# In the ChatTurn's iteration step:
reminder = build_budget_reminder(remaining)
GenServer.call(agent_pid, {:append_message, %{reminder | index: nil}})
```

The Agent stamps the index, appends, broadcasts. The reminder appears in the messages list at the next free slot, with a unique index. The next response will be at the slot AFTER the reminder, with its own unique index. No collision possible.

The current `system_reminder_received/2` handler in `LLMStreamHandler` is deleted entirely.

## File structure

### New files

- `lib/nest/agents/agent/chat_turn.ex` — the ChatTurn GenServer (~350 lines). The iteration state machine.
- `lib/nest/agents/agent/tool_loop/executor.ex` — the tool worker wrapper (~50 lines). Stateless, takes tool calls and a context, runs them, sends the result back.

### Significantly modified

- `lib/nest/agents/agent.ex` — shrinks to ~250 lines (from 503). Loses the `handle_chat/3`, the chat task spawning logic, the streaming handlers. Gains the `append_message` handler, the `get_messages` handler, the ChatTurn lifecycle event handlers.
- `lib/nest/agents/agent/chat_pipeline.ex` — shrinks to ~30 lines (from 427). Becomes just the `spawn_chat_turn/2` function (builds initial context, starts the GenServer). The user message append logic moves to the Agent's `handle_call({:chat, ...})`.
- `lib/nest/agents/agent/llm_runner.ex` — shrinks to ~150 lines (from 467). Becomes the stateless HTTP client: `request/2` returns a stream of canonical events. Loses `RunState`, `RunContext`, `build_tool_pair`, `maybe_inject_budget_warning`, `handle_max_iterations_with_tool_calls`, `run_with_new_client_after_tool_calls`.
- `lib/nest/agents/agent/llm_runner/late_call_handlers.ex` — deleted. Its functions either move to the ChatTurn (`maybe_inject_budget_warning` becomes a private function, `build_tool_pair` becomes a helper on the ChatTurn) or are no longer needed (`build_synthetic_error_pair` was a workaround for the bug the new design prevents).
- `lib/nest/agents/agent/handlers/llm_stream_handler.ex` — deleted. Its functions either move to the ChatTurn as private functions or are no longer needed (the streaming response finalization moves to the ChatTurn's `handle_info({:response_done, ...}, ...)`; the tool_calls/tool_results handling move to the ChatTurn as well; the budget reminder handling is part of the ChatTurn's iteration step).
- `lib/nest/agents/agent/handlers/compaction_handler.ex` — moves to the ChatTurn's namespace or becomes a private function. Compaction is a turn-scoped concern.
- `lib/nest/agents/agent/handlers/stop_handler.ex` — moves to the ChatTurn's namespace or becomes a private function. Stop is a turn-scoped concern.
- `lib/nest/agents/agent/handlers/api_log_handler.ex` — moves to the ChatTurn's namespace or becomes a private function. API logs are per-call, but the storage is on the Agent.

### Unchanged

- `lib/nest/agents/agent/chat_state.ex` — the `ChatState` struct stays, but the fields are split. The Agent-shaped state (history, llm_metrics) stays on the Agent. The turn-shaped state (messages, next_message_index, streaming_acc, api_log_sequences, chat_task_pid, cancelled) stays on the Agent too — the Agent is the storage layer. The ChatTurn has its own iteration state (iteration count, active worker pid, etc.) but it's a separate struct, not the Agent's `ChatState`.

  Wait, this needs clarification. The `messages` and `next_message_index` live on the Agent (storage). The `streaming_acc` is per-turn state, so it lives on the ChatTurn. The `api_log_sequences` is per-turn state too, so it lives on the ChatTurn. The `chat_task_pid` becomes `chat_turn_pid` and lives on the Agent (so the Agent can route `:stop_chat` to the active ChatTurn). The `cancelled` flag lives on the ChatTurn.

  The Agent's `ChatState` keeps: `messages`, `next_message_index`, `history`, `status`, `chat_turn_pid`, `active_message_index` (for the partial / streaming visualization), `llm_metrics` (which is its own struct already).

  The ChatTurn has its own state struct with: `iteration`, `max_iterations`, `force_finalize`, `active_worker`, `active_worker_kind`, `streaming_acc`, `api_log_sequences`, `cancelled`, `last_thinking`, `thinking_signature`.

- `lib/nest/agents/agent/init.ex` — unchanged. The Agent's init logic is still the same.
- `lib/nest/agents/agent/broadcasts.ex` — unchanged. The Agent still broadcasts on behalf of the active ChatTurn.
- `lib/nest/agents/agent/llm_metrics.ex` — unchanged.
- `lib/nest/agents/agent/system_prompt.ex` — unchanged.
- `lib/nest/llm/anthropic_client.ex`, `lib/nest/llm/openai_client.ex` — unchanged. They're already the right shape (stateless HTTP / SSE clients).
- `lib/nest_web/channels/agent_channel.ex` — minor changes. The `:chat_message` push logic stays the same; the `chat:sync` reply still reads from the Agent's state; the only change is the lifecycle events (`chat:crashed`, `chat:idle`) are now sent by the Agent on behalf of the ChatTurn.

### File count delta

- New: 2 files (~400 lines)
- Significantly modified: 8 files
- Deleted: 2 files
- Minor modifications: 1 file
- Unchanged: ~15 files

Net: roughly 500-800 lines added, 600-1000 lines removed. The end state is a much cleaner separation of concerns with fewer total lines.

## Test strategy

### Existing tests to update

- `test/nest/agents/agent_chat_test.exs` — most tests use `MockClient` to drive the iteration. They need to drive the ChatTurn GenServer instead of the chat task. The MockClient stays the same.
- `test/nest/agents/agent_system_messages_test.exs` — the budget reminder tests need to drive the ChatTurn's iteration step directly. The assertion that the reminder is in `state.chat_state.messages` becomes the assertion that the Agent received the `{:append_message, reminder}` call and the reminder is in the Agent's `chat_state.messages`.
- `test/nest/agents/agent_observability_test.exs` — same: drive the ChatTurn, assert on the Agent's `llm_metrics`.
- `test/nest/agents/agent_compaction_test.exs` — compaction is now a ChatTurn concern, but it can still be tested by driving the ChatTurn through enough iterations to trigger compaction.
- `test/nest_web/channels/agent_channel_chat_test.exs` — minor updates. The channel's role is unchanged; the Agent's role is slightly different (it stamps the index now).

### New tests to add

- `test/nest/agents/agent/chat_turn_test.exs` (~300 lines) — unit tests for the ChatTurn's iteration step. Cover: the budget reminder injection, the tool pair construction, the streaming response finalization, the max-iterations second-chance path, the stop signal, the crash handling.
- `test/nest/agents/agent_chat_turn_integration_test.exs` (~200 lines) — integration tests that drive the ChatTurn through end-to-end turns. Cover: a single-iteration turn, a multi-iteration turn, a turn that triggers compaction, a turn that the user stops, a turn that crashes.
- `assert_unique_message_indices/1` test helper in `test/support/agent_test_helpers.ex` (~20 lines) — a single function that asserts every message in the Agent's `chat_state.messages` has a unique `index` field. Called from every integration test that drives a turn to completion. This is the regression guard for the dual-counter bug class.

### Coverage

- New and modified production code: targeted for 90%+ coverage (the project target). The ChatTurn's iteration step is the highest-leverage code to cover, since it's the state machine.
- Test count: ~600 Elixir + ~581 JS → after the refactor ~700 Elixir + ~581 JS. The bump is mostly in the ChatTurn unit and integration tests.

## Migration order

The refactor is too big to land as one PR. Split it into 4 PRs, each independently mergeable:

### PR 1: introduce the `append_message` handler on the Agent

The smallest change that closes the dual-counter bug class. The Agent gets a new `handle_call({:append_message, message}, ...)` that stamps the index. The current handlers (which trust the message's `index` field) are updated to NOT trust the index and instead let the new handler stamp it.

This is the `next_state.message_index + 3 when a reminder is added` plan from earlier, but at the Agent level instead of the LLMRunner level. The Agent stamps the index. The LLMRunner stops setting it.

Files: `lib/nest/agents/agent/handlers/llm_stream_handler.ex`, `lib/nest/agents/agent.ex`, tests.

Size: ~80 lines. Risk: low — the change is additive and the existing tests still pass.

### PR 2: extract the HTTP client from the LLMRunner

`LLMRunner` shrinks from 467 lines to ~150. Loses `RunState`, `RunContext`, `build_tool_pair`, `maybe_inject_budget_warning`, `handle_max_iterations_with_tool_calls`, `run_with_new_client_after_tool_calls`. Becomes `Nest.LLM.Runner` (renamed) with one function: `request/2` that returns a stream of canonical events.

The `build_tool_pair` and `maybe_inject_budget_warning` move to a new module (call it `Nest.Agents.Agent.ChatTurn.Helpers` for now, or a private module) that the chat task can use. The chat task calls into these helpers to build messages, but doesn't set their indices.

Files: `lib/nest/agents/agent/llm_runner.ex`, `lib/nest/agents/agent/llm_runner/late_call_handlers.ex`, tests.

Size: ~300 lines removed, ~150 added. Risk: medium — the chat task is still the iteration driver, just with less state. The existing tests should still pass with minor updates.

### PR 3: introduce the ChatTurn GenServer

The chat task is replaced with the ChatTurn GenServer. The Agent spawns a ChatTurn child per turn, and the ChatTurn drives the iteration. The HTTP and tool workers are extracted from the LLMRunner (PR 2's work) and the ToolLoop into thin wrappers.

The Agent's `append_message` handler (from PR 1) is the only place the index is stamped. The ChatTurn queries the Agent for the messages list and tells the Agent to append messages.

The streaming handlers in `LLMStreamHandler` move to the ChatTurn's `handle_info/2` clauses. The stop handler moves too. The compaction handler moves too.

The chat pipeline shrinks to just the spawn logic.

Files: `lib/nest/agents/agent/chat_turn.ex` (new), `lib/nest/agents/agent.ex`, `lib/nest/agents/agent/chat_pipeline.ex`, `lib/nest/agents/agent/tool_loop.ex`, `lib/nest/agents/agent/handlers/`, tests.

Size: ~500 lines added (the new ChatTurn), ~700 lines removed (the deleted handlers and pipeline logic). Risk: high — this is the bulk of the refactor.

### PR 4: cleanup

Delete `late_call_handlers.ex` (it should be empty by now). Move the iteration-related helper functions to `ChatTurn` as private functions. Update the `ChatState` struct's field names (e.g., `chat_task_pid` → `chat_turn_pid`). Update the documentation in `notes/`.

Files: cleanup, docs, tests.

Size: ~100 lines. Risk: low — pure cleanup.

## What this fixes

- The dual-counter bug class. The Agent is the only writer of `index`; the ChatTurn never assigns an index. The reminder collision can't recur.
- The reminder is unremarkable. It's a regular message the ChatTurn decides to append. No `send/2` round-trip, no `system_reminder_received` handler, no cross-process state mutation.
- The state machine has a focused home. The ChatTurn is dedicated to iteration; the Agent is dedicated to storage and routing. Each process has a clear job.
- Sub-agents fall out for free. A child ChatTurn is a separate GenServer under the same Agent. The Agent's supervisor tracks parent → children relationships. The `clone_agent` tool becomes "spawn a child ChatTurn, await its `:chat_idle`, return the result as a tool result."

## What this enables

- **Concurrent sub-agent execution.** A child ChatTurn is a separate process. Multiple children can run concurrently under the same Agent. The supervisor tracks them; the Agent routes broadcasts.
- **Parallel tool execution.** The tool worker is a separate process. A future iteration could run multiple tool workers in parallel within a single ChatTurn, as long as the ChatTurn tracks which tool calls are pending and which are done.
- **Per-iteration cost estimation.** With the messages list on the Agent and the iteration state on the ChatTurn, computing "how much of the context window is this turn using" is straightforward. The Agent can pre-compute the context size at the start of each iteration and pass it to the ChatTurn for budget decisions.
- **Easier testing.** The HTTP worker is stateless and easy to mock. The tool worker is stateless and easy to mock. The ChatTurn is a state machine that's easy to drive through its transitions in tests. The Agent is a storage layer that's easy to query and assert against.

## Out of scope

- **Concurrent tool execution within a single turn.** The tool worker is a separate process, but the ChatTurn currently runs them sequentially. A future iteration could parallelize tool calls within a batch. Not part of this refactor.
- **Sub-agent implementation.** The refactor's design supports sub-agents naturally, but the actual `clone_agent` tool implementation is a separate task. The infrastructure is there; the tool itself comes later.
- **Persistent storage of conversation history.** The Agent's `chat_state.history` is in-memory. Persisting it to disk is a separate concern.
- **Migration of in-flight chats at deploy time.** If a user has an active turn when the new code is deployed, the in-flight chat task will be terminated (it's supervised by `Task.Supervisor`, which kills its children on shutdown). The user can re-send their message. This is acceptable for a one-time architectural refactor; we don't need to support a graceful migration of in-flight state.

## Open question for review

The one design decision I want to confirm before writing code: **should the ChatTurn have its own copy of the messages list (transferred from the Agent at the start of the turn), or should it always query the Agent for the messages list at the start of each iteration?**

The two options have different performance and complexity trade-offs:

- **ChatTurn has a copy.** Faster (no round-trip per iteration), but the ChatTurn has a copy of state that could drift from the Agent. We'd have to be careful about sync.
- **ChatTurn always queries.** Slower (one round-trip per iteration), but the Agent is the single source of truth. No drift possible.

The default in the plan is "always queries" — the round-trip is a `GenServer.call` which is cheap, and the single-source-of-truth guarantee is more valuable than the perf saving. The copy option is a possible optimization if profiling shows the round-trip is a bottleneck.

If you want the copy option, the design would change: the ChatTurn receives a snapshot of the messages at init, builds the LLM request from its local copy, and only queries the Agent for new messages when it needs to know about side-channel appends (which don't happen in the new design — all appends go through the Agent, so the ChatTurn's copy would be stale only if the Agent receives appends from outside the ChatTurn, which doesn't happen).

Actually, with the new design, the only appends are from the ChatTurn itself. So the ChatTurn could maintain a local copy that's always in sync (because it's the only writer). But then the ChatTurn has two pieces of state (iteration state AND messages list), and the messages list is no longer a single source of truth.

The "always queries" option keeps the Agent as the single source of truth at the cost of one round-trip per iteration. That's the cleanest. Going with that.
