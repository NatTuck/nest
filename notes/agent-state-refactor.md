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
---

## TODO: Complete the refactor

The refactor is incomplete. The current state (commits `46d3c74` and `84d23b2`) shipped a thin ChatTurn wrapper around `LLMRunner.run/2` but did not move the iteration into the ChatTurn. This caused 9 test regressions (all caused by the same `streaming_acc` race in the second turn). The TODOs below, when completed, will finish the refactor per the design above.

Each TODO is independently verifiable. Complete them in order. Stop and ask if any TODO is ambiguous.

### Phase 0: Reset to a clean baseline

- [ ] **TODO 0.1** — `git reset --hard 357f8e9` to revert PR 3 and PR 4. Keep PR 1 (`592c09e`) and PR 2 (`357f8e9`). Verify `mix test` shows 612 tests, 0 failures. The current branch is `main`; the working tree should be clean after the reset.

### Phase 1: Write the ChatTurn acceptance tests first

These tests are the contract. Write them before the implementation so we have a fast feedback loop. They drive the ChatTurn through every transition with a real Agent (not a mock). The 9 currently-failing tests are the smoke test — if they pass after the refactor, the refactor is correct.

- [ ] **TODO 1.1** — Create `test/nest/agents/agent/chat_turn_test.exs` with the following test cases. Each test starts a real Agent, starts a ChatTurn, and drives the iteration by sending events to the ChatTurn's mailbox. Use the existing `start_agent/1` helper and `MockClient` for LLM responses.

  - [ ] **1.1.1** — `test "single-iteration turn appends user + assistant, transitions to :idle"`. MockClient returns a final response. Assert: Agent receives `{:append_message, user_msg}` and `{:append_message, assistant_msg}` (in order, with stamped indices 1 and 2), Agent receives `{:chat_idle, chat_turn_pid}`, Agent's `chat_state.status` is `:idle`, `chat_state.chat_turn_pid` is `nil`.
  - [ ] **1.1.2** — `test "multi-iteration turn: response with tool calls → tool results → next response"`. MockClient returns: tool_call response, then final response. Assert: Agent receives `{:append_message, user}`, `{:append_message, assistant_with_tool_calls}`, `{:append_message, tool_result}`, `{:append_message, final_assistant}` (in order, with sequential indices).
  - [ ] **1.1.3** — `test "budget reminder is injected on iteration N-2, gets distinct index from next response"`. MockClient returns 4 tool_call responses then a final response. With `max_iterations = 5`, the reminder is injected on the 4th tool_call response. Assert: Agent receives `{:append_message, reminder}` before the 4th tool_call's `{:append_message, tool_result}`, the reminder's index and the final response's index are distinct.
  - [ ] **1.1.4** — `test "max iterations: second-chance call with synthetic error tool results"`. MockClient returns tool_call responses for 5 iterations, ignoring `tool_choice: :none` on the final call. Assert: Agent receives `{:append_message, synthetic_error_result}`, then a final `{:append_message, final_assistant}` with `force_finalize: true`.
  - [ ] **1.1.5** — `test "user-initiated stop kills the active HTTP worker, Agent finalizes partial"`. Start a ChatTurn with a slow LLM call. Send `{:stop_chat, self()}` to the ChatTurn. Assert: ChatTurn replies `:stopped` to the sender, ChatTurn sends `{:chat_stopped, self()}` to the Agent, the HTTP worker is killed, the partial assistant message (with whatever deltas were streamed) is finalized and broadcast.
  - [ ] **1.1.6** — `test "HTTP worker crash: Agent receives {:chat_crashed, exception, stacktrace}, transitions to :idle"`. Mock the HTTP call to raise. Assert: Agent receives `{:chat_crashed, exception, stacktrace}`, the exception + stacktrace is logged, the Agent's `chat_state.status` is `:idle`.
  - [ ] **1.1.7** — `test "nil usage is a no-op (second chat doesn't zero out accumulated usage)"`. Two chats, second has no `{:usage, _}` event. Assert: after second chat, `Agent.get_public_info(pid).usage.output_tokens` equals the first chat's `output_tokens` (not zero).
  - [ ] **1.1.8** — `test "multi-turn: message indices are strictly monotonic, no gaps, no duplicates"`. Two chats. Assert: `Enum.map(Agent.get_messages(pid), & &1.index) == [0, 1, 2, 3, 4]` (system, user1, asst1, user2, asst2). Use the `assert_unique_message_indices/1` helper from `test/support/agent_test_helpers.ex`.

- [ ] **TODO 1.2** — Run the new test file. All 8 tests should fail (the ChatTurn doesn't exist yet). Confirm the failure mode is "module not found" or "function not defined" — not a compile error in the test file itself.

- [ ] **TODO 1.3** — Verify the 9 currently-failing tests in `test/nest/agents/` and `test/nest_web/channels/` are still failing after the reset (TODO 0.1) and before the refactor. This is the baseline. Run `mix test` and note the 9 failures. They are:
  1. `test/nest_web/channels/agent_channel_messaging_test.exs:144` — status transitions idle → streaming → idle
  2. `test/nest_web/channels/agent_channel_advanced_test.exs:97` — API logs in two-round conversation
  3. `test/nest_web/channels/agent_channel_advanced_test.exs:25` — messages not lost on channel rejoin
  4. `test/nest_web/channels/agent_channel_advanced_test.exs:59` — sync after multiple rejoins
  5. `test/nest_web/channels/agent_channel_advanced_test.exs` — tool result chat:sync
  6. `test/nest_web/channels/agent_channel_chat_test.exs:30` — chat:sync returns messages after lastIndex
  7. `test/nest/agents/agent_system_messages_test.exs:111` — budget reminder persisted in messages
  8. `test/nest/agents/agent_observability_test.exs:210` — accumulates output_tokens across turns
  9. `test/nest/agents/agent_observability_test.exs:286` — nil usage is a no-op

  Note: the exact list may shift by 1-2 tests depending on test ordering. The point is: after TODO 0.1, there should be 9 failures, and after the refactor (Phase 4), all 9 should pass without any test changes (except TODO 5.1 which updates the crash test stub).

### Phase 2: Implement the ChatTurn

The ChatTurn owns the iteration. It calls `Nest.LLM.Runner.request/2` directly (no wrapper module). The HTTP worker and tool worker are plain `Task`s spawned by the ChatTurn. The Agent is the single source of truth for messages; the ChatTurn queries via `GenServer.call(:get_messages)` before each LLM call.

- [ ] **TODO 2.1** — Rewrite `lib/nest/agents/agent/chat_turn.ex` (~400 lines). The module structure:

  ```elixir
  defmodule Nest.Agents.Agent.ChatTurn do
    use GenServer, restart: :temporary

    defmodule State do
      defstruct [
        :agent_pid,
        :ctx,                    # map: client_config, tools, tool_choice, agent_pid, agent_id, caps, context_limit, context_limit_source
        :iteration,              # 0..max_iterations
        :max_iterations,
        :force_finalize,
        :active_worker,          # pid | nil
        :active_worker_kind,     # :http | :tools | nil
        :cancelled,
        :streaming_acc,          # Streaming.AssistantAccumulator | nil
        :api_log_sequences,      # map of message_index -> sequence
        :last_thinking,          # String.t() | nil
        :messages_snapshot       # list (cached for tool workers)
      ]
    end

    def start_link(args) do
      GenServer.start_link(__MODULE__, args)
    end

    @impl true
    def init({agent_pid, ctx, init_state}) do
      Process.flag(:trap_exit, true)
      Process.put(:"$callers", [agent_pid])  # Mimic permissions
      Process.send(self(), :iterate, [])
      state = %State{
        agent_pid: agent_pid,
        ctx: ctx,
        iteration: 0,
        max_iterations: init_state.max_iterations,
        force_finalize: false,
        active_worker: nil,
        active_worker_kind: nil,
        cancelled: false,
        streaming_acc: Streaming.new(compute_next_index(ctx)),
        api_log_sequences: %{},
        last_thinking: nil,
        messages_snapshot: []
      }
      {:ok, state}
    end

    @impl true
    def handle_info(:iterate, state), do: iterate(state)
    def handle_info({:http_response, response}, state), do: handle_response(response, state)
    def handle_info({:tool_results, results}, state), do: handle_tool_results(results, state)
    def handle_info({:stop_chat, from}, state), do: stop_chat(from, state)
    def handle_info({:EXIT, pid, reason}, state), do: worker_exited(pid, reason, state)
    def handle_info(_, state), do: {:noreply, state}

    # The iteration step. Queries the Agent for messages,
    # checks the iteration budget, injects a reminder if
    # needed, and spawns the HTTP worker.
    defp iterate(state) do
      state = maybe_inject_budget_reminder(state)
      state = %{state | iteration: state.iteration + 1}
      messages = GenServer.call(state.agent_pid, :get_messages)
      state = %{state | messages_snapshot: messages}
      spawn_http_worker(state, messages)
    end

    # Check if we're at the iteration cap. If so, append a
    # system reminder via the Agent. The Agent stamps the
    # index; the next response will be stamped at
    # next_message_index + 1, so no collision.
    defp maybe_inject_budget_reminder(state) do
      remaining = state.max_iterations - state.iteration
      case Helpers.maybe_inject_budget_reminder(remaining) do
        nil -> state
        reminder ->
          {:ok, _stamped} = GenServer.call(state.agent_pid, {:append_message, reminder})
          state
      end
    end

    # Spawn the HTTP worker as a Task under the TaskSupervisor.
    # The worker calls Nest.LLM.Runner.request/2 and sends the
    # result back to the ChatTurn via {:http_response, response}
    # or {:http_error, error}. Deltas, api_logs, and thinking
    # signatures are sent from the worker to the Agent
    # directly (the Agent re-broadcasts and stores).
    defp spawn_http_worker(state, messages) do
      task = Task.Supervisor.start_child(
        Nest.Agents.TaskSupervisor,
        fn -> http_worker_fun(messages, self(), state) end
      )
      Process.monitor(task.pid)
      {:noreply, %{state | active_worker: task.pid, active_worker_kind: :http}}
    end

    # The HTTP worker. Plain Task, runs in its own process.
    # Uses streaming callbacks to forward deltas to the
    # Agent directly (re-broadcast) and update the
    # ChatTurn's local streaming_acc.
    defp http_worker_fun(messages, chat_turn_pid, state) do
      streaming_acc = state.streaming_acc
      callbacks = %{
        on_text: fn text, sent ->
          new_acc = Streaming.append_text(streaming_acc, text)
          Agent.forward_delta(state.agent_pid, text, :text, sent.chars, state.streaming_acc_index)
          %{sent | chars: sent.chars + String.length(text)}
        end,
        on_thinking: fn text, sent ->
          new_acc = Streaming.append_thinking(streaming_acc, text)
          Agent.forward_delta(state.agent_pid, text, :thinking, sent.chars, state.streaming_acc_index)
          %{sent | chars: sent.chars + String.length(text)}
        end,
        on_signature: fn sig ->
          send(state.agent_pid, {:thinking_signature_received, sig})
        end,
        on_error: fn error ->
          Agent.forward_error(state.agent_pid, error, state.streaming_acc_index)
        end,
        on_response: fn _ -> :ok end,
        should_stop: &check_should_stop?/0
      }
      request = %LLM.RunRequest{
        messages: messages,
        tools: state.ctx.tools,
        tool_choice: state.ctx.tool_choice,
        model: state.ctx.client_config.model,
        metadata: %{}
      }
      opts = [
        base_url: state.ctx.client_config.base_url,
        api_key: state.ctx.client_config.api_key,
        receive_timeout: state.ctx.client_config.receive_timeout,
        agent_pid: state.agent_pid
      ]
      case state.ctx.client_config.client.run(request, opts) do
        {:ok, stream} ->
          case Nest.LLM.StreamConsumer.reduce(stream, %Nest.LLM.StreamConsumer{
            on_text: callbacks.on_text,
            on_thinking: callbacks.on_thinking,
            on_signature: callbacks.on_signature,
            should_stop: callbacks.should_stop
          }) do
            {acc, %LLM.RunResponse{} = response, nil, _} ->
              normalized = Nest.LLM.Client.finalize(acc, response.model) |> ...merge...
              send(chat_turn_pid, {:http_response, normalized})
            {_acc, nil, nil, _sent} ->
              :ok  # cooperative stop
            {_acc, _response, error, _sent} when not is_nil(error) ->
              send(chat_turn_pid, {:http_error, error})
          end
        {:error, reason} ->
          send(chat_turn_pid, {:http_error, reason})
      end
    end

    # The HTTP worker completed. Append the response to the
    # Agent via GenServer.call. If the response has tool calls,
    # either spawn the tool worker (normal case) or handle the
    # max-iterations second-chance case. If it's a final text
    # response, send {:chat_idle, self()} to the Agent and
    # stop.
    defp handle_response(response, state) do
      state = %{state | active_worker: nil, active_worker_kind: nil, last_thinking: response.thinking}

      # Build the assistant message with the streaming_acc's
      # accumulated state. The Agent stamps the index.
      assistant_msg = %{
        role: :assistant,
        content: response.text,
        thinking: response.thinking,
        thinking_signature: state.streaming_acc.thinking_signature,
        tool_calls: response.tool_calls,
        index: nil,
        timestamp: DateTime.utc_now(),
        api_logs: []
      }
      {:ok, stamped} = GenServer.call(state.agent_pid, {:append_message, assistant_msg})
      # Update the api_log_sequences based on the stamped index
      # (the Agent's append_message handler incremented sequences).
      state = %{state | api_log_sequences: fetch_sequences(state.agent_pid)}

      cond do
        state.force_finalize ->
          # Second-chance call: always treat as final.
          finalize_turn(state)

        LLM.RunResponse.has_tool_calls?(response) and state.iteration >= state.max_iterations ->
          # Max iterations, LLM still emitted tool calls.
          # Synthesize error tool results, recurse with
          # force_finalize: true.
          error_results = Enum.map(response.tool_calls, fn tc ->
            %Nest.Messages.ToolResult{
              tool_call_id: tc.id, name: tc.name,
              content: "Max tool iterations reached", is_error: true
            }
          end)
          tool_msg = %{
            role: :tool, tool_results: error_results,
            index: nil, timestamp: DateTime.utc_now(), api_logs: []
          }
          GenServer.call(state.agent_pid, {:append_message, tool_msg})
          state = %{state | force_finalize: true}
          Process.send(self(), :iterate, [])
          {:noreply, state}

        LLM.RunResponse.has_tool_calls?(response) ->
          # Normal tool call: spawn the tool worker.
          spawn_tool_worker(state, response.tool_calls)

        true ->
          # Final text response.
          finalize_turn(state)
      end
    end

    # The tool worker completed. Append the tool results to
    # the Agent, then start the next iteration.
    defp handle_tool_results(results, state) do
      state = %{state | active_worker: nil, active_worker_kind: nil}
      tool_msg = %{
        role: :tool, tool_results: results,
        index: nil, timestamp: DateTime.utc_now(), api_logs: []
      }
      GenServer.call(state.agent_pid, {:append_message, tool_msg})
      Process.send(self(), :iterate, [])
      {:noreply, state}
    end

    # User clicked Stop. Kill the active worker, notify the
    # Agent, and stop.
    defp stop_chat(from, state) do
      send(from, :stopped)
      if state.active_worker, do: Process.exit(state.active_worker, :kill)
      state = %{state | active_worker: nil, active_worker_kind: nil, cancelled: true}
      send(state.agent_pid, {:chat_stopped, self()})
      {:stop, :normal, state}
    end

    # A worker died. Normal/killed exits are expected (the
    # stop handler killed the worker, or the tool worker
    # completed normally). Other exits are crashes.
    defp worker_exited(_pid, :normal, state), do: {:noreply, state}
    defp worker_exited(_pid, :killed, state), do: {:noreply, state}
    defp worker_exited(_pid, reason, state) do
      send(state.agent_pid, {:chat_crashed, reason, __STACKTRACE__})
      {:stop, :normal, state}
    end

    # Send {:chat_idle, self()} to the Agent and stop.
    defp finalize_turn(state) do
      send(state.agent_pid, {:chat_idle, self()})
      send(state.agent_pid, {:api_log_sequences_updated, state.api_log_sequences})
      {:stop, :normal, state}
    end

    # Non-blocking mailbox check for {:stop_chat, _}.
    defp check_should_stop? do
      receive do
        {:stop_chat, from} -> send(from, :stopped); true
      after
        0 -> false
      end
    end
  end
  ```

  The helpers (`Helpers.maybe_inject_budget_reminder/1`, `Helpers.build_tool_message/2`, `Helpers.build_assistant_message/2`, `Helpers.build_synthetic_error_tool_results/2`) move to `lib/nest/agents/agent/chat_turn/helpers.ex` (renamed from `lib/nest/agents/agent/chat_turn/helpers.ex`'s current location; the file already exists from PR 2 with the `late_call_handlers` functions moved into it).

  The `compute_next_index/1` helper queries the Agent for the current `next_message_index` via `GenServer.call(state.agent_pid, :get_next_index)` (a new Agent handler added in TODO 3.4).

- [ ] **TODO 2.2** — Verify the ChatTurn compiles. `mix compile` should succeed. If there are errors, fix them and re-run.

- [ ] **TODO 2.3** — Run the ChatTurn test file (`test/nest/agents/agent/chat_turn_test.exs`). All 8 tests should still fail (the Agent doesn't have the new `handle_call` clauses yet — TODO 3). The failure mode should be "function not defined" or "no clause matches in handle_call", not a compile error.

### Phase 3: Update the Agent

The Agent needs new `handle_call` and `handle_info` clauses to support the ChatTurn's contract. The existing handlers in `lib/nest/agents/agent/handlers/llm_stream_handler.ex` and `lib/nest/agents/agent/handlers/stop_handler.ex` are simplified (the message-append logic moves to `__append_message__/2` from PR 1; the stop handler just forwards to the ChatTurn).

- [ ] **TODO 3.1** — Add these new `handle_call` clauses to `lib/nest/agents/agent.ex` (in the `handle_call/2` function, near the existing `:get_messages` and `:get_chat_turn_pid` clauses):

  ```elixir
  def handle_call(:get_messages, _from, state) do
    {:reply, state.chat_state.messages, state}
  end

  def handle_call(:get_next_index, _from, state) do
    {:reply, state.chat_state.next_message_index, state}
  end

  def handle_call({:record_api_log, message_index, api_log_id, payload}, _from, state) do
    pending = Map.get(state.chat_state.pending_api_logs, message_index, [])
    pending = pending ++ [%{id: api_log_id, timestamp: DateTime.utc_now(), type: :request, payload: payload}]
    state = put_in(state.chat_state.pending_api_logs[message_index], pending)
    {:reply, :ok, state}
  end
  ```

  Note: `:get_messages` may already exist from PR 1 — if so, don't add it twice. Check `lib/nest/agents/agent.ex` first.

- [ ] **TODO 3.2** — Add these new `handle_info` clauses to `lib/nest/agents/agent/handlers/llm_stream_handler.ex` (in the `handle/2` dispatch function and the corresponding `defp` functions):

  ```elixir
  # In the handle/2 dispatch, add:
  def handle({:delta_received, content, part_type}, state) do
    delta_received(content, part_type, state)
  end
  def handle({:thinking_signature_received, sig}, state) do
    thinking_signature_received(sig, state)
  end
  def handle({:llm_usage, usage}, state) do
    llm_usage(usage, state)
  end
  def handle({:api_log, message_index, api_log_id, payload}, state) do
    api_log(message_index, api_log_id, payload, state)
  end
  def handle({:api_log_sequences_updated, sequences}, state) do
    api_log_sequences_updated(sequences, state)
  end
  def handle({:chat_idle, _pid}, state) do
    chat_idle(state)
  end
  def handle({:chat_stopped, _pid}, state) do
    chat_stopped(state)
  end
  def handle({:chat_crashed, exception, stacktrace}, state) do
    chat_crashed(exception, stacktrace, state)
  end

  # The implementations. The delta/usage/api_log handlers
  # are thin (just update local state and broadcast). The
  # chat_idle/chat_stopped/chat_crashed handlers transition
  # the Agent's state and finalize the partial.

  defp delta_received(content, part_type, state) do
    # Re-broadcast the delta via PubSub. The ChatTurn owns
    # the streaming_acc now; the Agent just forwards.
    acc = state.chat_state.streaming_acc
    message_index = if acc, do: acc.index, else: 0
    case part_type do
      :text -> Broadcasts.delta_text(state.id, message_index, content, 0)
      :thinking -> Broadcasts.delta_thinking(state.id, message_index, content, 0)
    end
    {:noreply, state}
  end

  defp thinking_signature_received(sig, state) do
    # The ChatTurn owns the streaming_acc and copies the
    # signature into the assistant message when it appends.
    # The Agent doesn't need to store it. If we want the
    # signature available via get_public_info, the ChatTurn
    # can send {:partial_update, streaming_acc} events.
    # For now, no-op.
    {:noreply, state}
  end

  defp llm_usage(usage, state) do
    state = %{state | llm_metrics: %{state.llm_metrics |
      usage_totals: Broadcasts.merge_usage_totals(state.llm_metrics.usage_totals, usage)
    }}
    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  defp api_log(message_index, api_log_id, payload, state) do
    # Store in pending_api_logs. When the message at this
    # index is appended via __append_message__/2, the
    # pending logs are attached.
    pending = Map.get(state.chat_state.pending_api_logs, message_index, [])
    log = %{id: api_log_id, timestamp: DateTime.utc_now(), type: :request, payload: payload}
    pending = pending ++ [log]
    state = put_in(state.chat_state.pending_api_logs[message_index], pending)
    {:noreply, state}
  end

  defp api_log_sequences_updated(sequences, state) do
    state = %{state | chat_state: %{state.chat_state |
      api_log_sequences: sequences,
      chat_turn_pid: nil,
      cancelled: false
    }}
    {:noreply, state}
  end

  defp chat_idle(state) do
    state = %{state | chat_state: %{state.chat_state |
      status: :idle, chat_turn_pid: nil, cancelled: false
    }}
    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  defp chat_stopped(state) do
    # Finalize the partial streaming_acc as an assistant message.
    state = finalize_partial_if_any(state)
    state = %{state | chat_state: %{state.chat_state |
      status: :idle, chat_turn_pid: nil, cancelled: false
    }}
    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  defp chat_crashed(exception, stacktrace, state) do
    state = finalize_partial_if_any(state)
    error_msg = format_chat_task_error(exception, stacktrace)
    Broadcasts.error(state.id, state.chat_state.next_message_index, error_msg, "ChatTurn.run_chat_task/1")
    state = %{state | chat_state: %{state.chat_state |
      status: :idle, chat_turn_pid: nil, cancelled: false
    }}
    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  defp finalize_partial_if_any(state) do
    case state.chat_state.streaming_acc do
      %Streaming.AssistantAccumulator{text_buffer: "", thinking_buffer: ""} -> state
      %Streaming.AssistantAccumulator{} = acc ->
        partial_msg = build_partial_assistant_message(acc, state)
        {_stamped, state} = Agent.__append_message__(state, partial_msg)
        %{state | chat_state: %{state.chat_state | streaming_acc: nil}}
      nil -> state
    end
  end
  ```

  The `build_partial_assistant_message/2` and `format_chat_task_error/2` helpers exist in the current `llm_stream_handler.ex` — move them to a shared module or keep them here.

- [ ] **TODO 3.3** — Simplify the stop handler in `lib/nest/agents/agent/handlers/stop_handler.ex`. The `stop_chat_requested/2` function should just send `{:stop_chat, from}` to `state.chat_state.chat_turn_pid`. The `chat_stopped/2` function is removed (the new `handle_info({:chat_stopped, _pid}, state)` in TODO 3.2 handles it).

  ```elixir
  def handle({:stop_chat, from}, state) do
    stop_chat_requested(from, state)
  end

  defp stop_chat_requested(from, state) do
    if state.chat_state.chat_turn_pid do
      send(state.chat_state.chat_turn_pid, {:stop_chat, from})
    else
      send(from, :stopped)
    end
    state = %{state | chat_state: %{state.chat_state | cancelled: true}}
    {:noreply, state}
  end
  ```

- [ ] **TODO 3.4** — Simplify the `handle_cast({:chat, content, mode}, state)` in `lib/nest/agents/agent.ex`. The cast should:
  1. Resolve the mode and build the user message.
  2. `clear_cancelled`.
  3. Call `__append_message__(state, user_message)` to append the user message (Agent stamps the index, broadcasts).
  4. Set the initial `streaming_acc` for the ChatTurn: `state.chat_state.streaming_acc = Streaming.new(stamped_index + 1)`.
  5. Run the preflight compaction check. If compaction is needed, spawn a compaction task; on completion, the compaction continuation calls `spawn_chat_turn/1` with the compacted messages. If no compaction is needed, call `spawn_chat_turn/1` directly.
  6. Return `{:noreply, state}`.

  The `spawn_chat_turn/1` function is in `lib/nest/agents/agent/chat_pipeline.ex` (TODO 4.1).

- [ ] **TODO 3.5** — Run the ChatTurn test file. All 8 tests should still fail (the ChatTurn is calling new Agent handlers that don't exist). The failure mode should be "no clause matches in handle_call" or similar.

### Phase 4: Delete the old iteration logic

- [ ] **TODO 4.1** — Simplify `lib/nest/agents/agent/chat_pipeline.ex` to ~50 lines. The entire file is now just:
  - `spawn_chat_turn/1` — builds the ctx and init_state maps, calls `ChatTurnSupervisor.start_chat_turn/3`.
  - `maybe_compact_then_spawn/4` — runs the preflight check, spawns compaction if needed (with a continuation that calls `spawn_chat_turn/1` on completion), or spawns the ChatTurn directly.
  - `resolve_mode_and_caps/2`, `build_user_messages/3`, `build_user_message/3`, `build_llm_messages/3`, `preflight_decision/2`, `streaming_active?/1` — keep these helpers.

  Delete: `spawn_chat_task/3` (replaced by `spawn_chat_turn/1`), `broadcast_user_and_prepare_streaming/3` (moved to the Agent's `handle_cast`), `build_run_context/4`, `build_run_state/1`, `run_chat_task_and_notify/3`, and the `rescue` clause (the ChatTurn is now owned by the Agent's supervision tree, not a `Task.Supervisor`).

- [ ] **TODO 4.2** — Delete `lib/nest/agents/agent/llm_runner.ex`. The iteration loop moves to the ChatTurn (TODO 2.1). The `LLM.Runner.request/2` call is the only thing left, and it goes directly from the ChatTurn. Delete the `RunState`, `RunContext`, `Consumer` modules, and all the iteration logic (`run_with_new_client`, `handle_max_iterations_with_tool_calls`, `run_with_new_client_after_tool_calls`, `handle_new_response`, `send_final_assistant`, `broadcast_new_request_log`, `broadcast_new_response_log`).

- [ ] **TODO 4.3** — Verify the project compiles after the deletion. `mix compile` should succeed. If there are references to `LLMRunner.run/2` or `LLMRunner.RunState`/`RunContext` in tests or other modules, update them.

- [ ] **TODO 4.4** — Move the `Helpers` functions. The current `lib/nest/agents/agent/chat_turn/helpers.ex` (from PR 2) has `build_tool_pair/3`, `build_synthetic_error_pair/3`, `maybe_inject_budget_warning/4`, and `new_state/4`. Rename and refactor:
  - `build_tool_pair/3` → `build_assistant_message/2` (takes a response, returns the message struct with `index: nil`).
  - `build_synthetic_error_pair/3` → `build_synthetic_error_tool_results/2` (takes tool_calls, returns the tool message struct with `index: nil`).
  - `maybe_inject_budget_warning/4` → `maybe_inject_budget_reminder/1` (takes the remaining count, returns the system reminder message or nil).
  - `new_state/4` → delete (the ChatTurn builds its own state in `init/1`).

  Keep `@max_iterations_error_content` as a module attribute.

- [ ] **TODO 4.5** — Run the full test suite. The 8 ChatTurn tests should now pass (the implementation matches the tests). The 9 previously-failing tests should also now pass. The other ~596 tests should still pass. Total: 613 tests, 0 failures.

  If any test fails, debug. The failure modes are:
  - **ChatTurn test fails** — the ChatTurn's state machine has a bug. Check the `handle_info` clauses and the `iterate/1` function.
  - **Previously-failing test still fails** — the Agent's new handlers don't correctly support the ChatTurn's contract. Check the new `handle_call` and `handle_info` clauses.
  - **Previously-passing test now fails** — a regression. The most likely cause is that the old `LLMRunner.run/2` was stubbed in a test, and the stub now needs to be at the new boundary (TODO 5.1).

### Phase 5: Update the crash test stub

- [ ] **TODO 5.1** — Update `test/nest/agents/chat_task_crash_test.exs`. The 4 tests in this file stub `Nest.Agents.Agent.LLMRunner.run/2` to raise or send deltas. After the refactor, the ChatTurn calls `Nest.LLM.Runner.request/2` directly (via the HTTP worker). The stubs need to move to the new boundary.

  For each test, replace:
  ```elixir
  Mimic.stub(Nest.Agents.Agent.LLMRunner, :run, fn _ctx, _state -> ... end)
  ```
  with:
  ```elixir
  Mimic.stub(Nest.LLM.MockClient, :run, fn _request, _opts -> ... end)
  ```

  The `send(pid, {:delta_received, ...})` inside the stub now goes from the test process to the Agent. The Agent's `delta_received` handler re-broadcasts via PubSub. The ChatTurn's HTTP worker sends the delta to the Agent. The test's `send(pid, ...)` should still work because the Agent processes it.

  The `Mimic.allow(Nest.Agents.Agent.LLMRunner, self(), pid)` line becomes `Mimic.allow(Nest.LLM.MockClient, self(), pid)`.

  Verify the stacktrace assertion `assert content =~ "chat_turn.ex"` still passes (the ChatTurn's `run_chat_task` is now where the try/catch lives, but the error path in `ChatTurn.run_chat_task/1` may not be there anymore — the HTTP worker's error becomes `{:http_error, error}` which the ChatTurn forwards to the Agent as `{:chat_crashed, ...}`). If the stacktrace check fails, update it to match the new error path.

- [ ] **TODO 5.2** — Run the full test suite again. All 613 tests should pass.

### Phase 6: Final verification

- [ ] **TODO 6.1** — Run `mix precommit`. The full precommit suite (credo, biome, mix test, vitest) should pass. Credo should be clean (the `chat_turn.ex` file is ~400 lines, under the 500-line cap; the simplified `agent.ex` is ~350 lines; the simplified `chat_pipeline.ex` is ~50 lines).

- [ ] **TODO 6.2** — Run the regression guard from PR 1: `assert_unique_message_indices/1` should be called from the ChatTurn integration test. The helper exists at `test/support/agent_test_helpers.ex`. Add a call to it in TODO 1.1.8.

- [ ] **TODO 6.3** — Commit. `git add -A && git commit -m "PR 3: ChatTurn drives the iteration, queries Agent for messages"`. The diff should be:
  - `lib/nest/agents/agent/chat_turn.ex`: ~400 lines (rewrite)
  - `lib/nest/agents/agent/chat_turn/helpers.ex`: ~50 lines (refactor)
  - `lib/nest/agents/agent/llm_runner.ex`: deleted (~390 lines removed)
  - `lib/nest/agents/agent/chat_pipeline.ex`: ~50 lines (simplify)
  - `lib/nest/agents/agent.ex`: +30 lines (new handle_call/handle_info clauses)
  - `lib/nest/agents/agent/handlers/llm_stream_handler.ex`: +80 lines (new handlers), -200 lines (message-append logic removed)
  - `lib/nest/agents/agent/handlers/stop_handler.ex`: -50 lines (simplified to forward)
  - `test/nest/agents/agent/chat_turn_test.exs`: new, ~300 lines
  - `test/nest/agents/chat_task_crash_test.exs`: ~20 lines changed (stub update)

  Net: roughly 0 lines added (400 new - 390 deleted), but the structure is much cleaner.

- [ ] **TODO 6.4** — Verify the git log shows a clean history:
  - `7ac7f8b` — docs: add agent-state-refactor plan
  - `592c09e` — PR 1: Agent becomes sole writer of message index
  - `357f8e9` — PR 2: extract HTTP client to Nest.LLM.Runner
  - `<new commit>` — PR 3: ChatTurn drives the iteration, queries Agent for messages

  (No PR 4 needed — the `chat_task_pid` → `chat_turn_pid` rename happens naturally in PR 3.)

---

## Completion criteria

The refactor is complete when all of the following are true:

1. All 613 tests pass.
2. `mix precommit` is clean.
3. The ChatTurn owns the iteration. `lib/nest/agents/agent/llm_runner.ex` is deleted.
4. The Agent is the single source of truth for `messages`. The ChatTurn queries via `GenServer.call(:get_messages)`.
5. The dual-counter bug class is structurally fixed. `assert_unique_message_indices/1` passes for every test that drives a turn to completion.
6. The budget reminder is a regular appended system message. The reminder and the next response have distinct indices. Verified by `test/nest/agents/agent_system_messages_test.exs:151`.
7. The stop signal flows Agent → ChatTurn → HTTP worker (kill). The partial is finalized by the Agent's `chat_stopped` handler. Verified by `test/nest/agents/agent_stop_test.exs`.
8. The crash signal flows HTTP worker → ChatTurn → Agent. The Agent's `chat_crashed` handler finalizes the partial and broadcasts `chat:error`. Verified by `test/nest/agents/chat_task_crash_test.exs`.
