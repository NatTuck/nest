# Extract compaction from the chat task; make the chat task resumable

## Background

The chat task (`Nest.Agents.Agent.ChatTurn`) is the per-turn state
machine that drives the LLM call chain. It's a `:temporary` GenServer
spawned by `ChatTurnSupervisor`, living only for the duration of one
chat turn. Its job is to:

1. Call the LLM with the agent's current messages.
2. Process the response (final text or tool calls).
3. If the response has tool calls, execute them, append the tool
   results, and call the LLM again.
4. Repeat until the LLM returns a final text response, the user
   clicks Stop, the iteration cap is hit, or something crashes.

The chat task uses the Agent as the single source of truth for
messages: it queries via `GenServer.call(:get_messages_with_cancelled)`
before each iteration and appends via
`GenServer.call({:append_message, _})` after each response.

Compaction currently happens *inside* the chat task's loop. This
note describes why that's wrong, what the current flow looks like,
and what the redesign should be.

## Current flow

### Preflight (every iteration)

Every iteration of the chat task starts with a preflight check:

```
ChatTurn.safe_iterate/1
  → GenServer.call(agent_pid, :get_messages_with_cancelled)
  → Iteration.dispatch_preflight(state, messages)
    → Preflight.run(state)
      → send(agent_pid, {:preflight_request, self(), messages})
      → receive do {:preflight_result, :proceed | :compacted, _} end
        (blocks for up to 30s; on timeout, proceeds with current snapshot)
      → returns :proceed or {:compacted, compacted_messages}
```

The Agent's `CompactionHandler.preflight_request/3` decides whether
to compact and either:

- Replies `:proceed` (no compaction needed), or
- Calls `Compaction.spawn/5` with `{:preflight_continuation, task_pid}`,
  then waits for `{:compaction_done, _, _}` or
  `{:compaction_failed_for_preflight, task_pid, _}`. On failure,
  the existing handler replies `:proceed` with the original
  messages, on the theory that "any snapshot is better than
  deadlock."

When the preflight finishes, the chat task uses the returned
messages (either the compacted set or the existing snapshot) for
its next LLM call.

### `context` tool's `compact` action

When the LLM emits a tool call for the `context` tool with
`action: "compact"`, the chat task's `request_compaction_from_task/2`
sends `{:task_compaction_request, self(), focus}` to the Agent and
**blocks in a `receive`** for the result:

```
receive do
  {:task_compaction_done, new_messages} -> "Compacted N messages..."
  {:task_compaction_failed, reason} -> "Compaction failed: ..."
  {:stop_chat, from} -> :stopped
after
  @compaction_timeout -> "Compaction timed out"
end
```

This is the *only* `compact`-action entry point from the chat task.
The chat task synthesizes the tool result string and the next LLM
call (with the tool result in the messages) happens on the same
chat task.

### Compaction itself (`Compaction.spawn/5`)

`Compaction.spawn/5` runs a `Task.Supervisor.start_child` that
calls `Nest.Tokens.Compactor.compact/3`. On `{:ok, _}` it sends
`{:compaction_done, new_messages, continuation}` to the Agent. On
`{:error, _}` it dispatches to one of three failure paths keyed by
the continuation shape:

- `{:preflight_continuation, task_pid}` → `{:compaction_failed_for_preflight, task_pid, reason}` — chat task proceeds with original messages.
- `{:task_compaction_continuation, task_pid}` → `{:task_compaction_failed, task_pid, reason}` — chat task turns the reason into a synthetic error tool result.
- `{:chat_continuation, _}` → fall back to `send_failure/4` which sends `{:compaction_done, original_messages, continuation}` — the Agent proceeds as if compaction succeeded with the original messages as the "compacted" output. This is wrong: the user's message is appended once in `handle_chat/3` and again in `resume_after_compaction/3`.

### `CompactionHandler.compaction_done/3` (success)

When the compactor returns `{:ok, _}`, the Agent's handler:

1. Calls `regenerate_for_compaction/2` (extracts the compactor's
   summary text from position 0, re-renders the system prompt,
   encodes the summary as a user message, and renumbers the
   compactor's other output starting at `marker_index + 3`).
2. Calls `archive_and_compact/2` which:
   - Archives `state.chat_state.messages` in the DB with
     `archived_at` set.
   - Inserts a `:compaction` marker at `marker_index`
     (= pre-swap `next_message_index`).
   - Replaces `state.chat_state.messages` with the re-encoded
     compacted state.
   - Persists the marker and the new state to the DB.
3. Routes by continuation:
   - `{:chat_continuation, {content, mode}}` → calls
     `ChatPipeline.resume_after_compaction/3` which builds a new
     user message, calls `__append_message__/2` (appending the
     user message *again* — see below), and spawns a chat turn.
   - `{:preflight_continuation, task_pid}` → sends `{:preflight_result, :compacted, new_messages}` to the chat task. The chat task uses these for the next LLM call.
   - `{:task_compaction_continuation, task_pid}` → sends `{:task_compaction_done, new_messages}` to the chat task. The chat task synthesizes the tool result and makes the next LLM call.

## Problems with the current flow

### 1. The chat task waits synchronously for the compactor

`request_compaction_from_task/2` blocks the chat task in a
`receive` for up to 60 seconds (`@compaction_timeout`). If the
compactor fails and the user wants to retry three weeks later, the
chat task is already dead — the retry can't continue its
conversation.

Same problem with the preflight path: the chat task blocks in
`Preflight.run/1` for up to 30 seconds. If the preflight decides
compaction is needed and the user wants to retry three weeks
later, the chat task is dead.

### 2. The `chat_continuation` path silently corrupts state on failure

`Compaction.spawn/5`'s `send_failure/4` for `{:chat_continuation, _}`
sends `{:compaction_done, original_messages, continuation}` — the
original messages treated as if they were the compacted output.
The Agent's `compaction_done/3` then runs `regenerate_for_compaction/2`
on the original messages, which extracts the leading system as the
"summary" and re-encodes the rest. The result is a corrupted
in-memory state.

### 3. The `chat_continuation` path appends the user message twice

`handle_chat/3` appends the user message via `__append_message__/2`.
On compactor success, `ChatPipeline.resume_after_compaction/3` calls
`__append_message__/2` *again* with a freshly-built user message
using the same `(content, mode)`. The original is archived by the
compactor's swap, so the user message appears in both the archived
history and the active state.

### 4. The compactor's failure mode pretends success

Even on LLM-call failure, the Agent proceeds with the
"compaction done" path (with the original messages as the
"compacted" output). The agent doesn't know the compaction failed,
the DB write happens anyway, and the broadcast `chat:compaction`
fires. There's no signal to the user that the compaction didn't
actually compact anything.

### 5. The compactor emits literal placeholders

`Compactor.wrap_summary/2` produces `"[Summary of earlier conversation]"`
when the LLM returns empty, and wraps real summaries with
`"[Summary of earlier conversation]:\n\n<text>"`. This violates
the project's UI transparency principle. The handler then extracts
the wrong position (`summary_text` comes from position 0 — the
original system — instead of position 1 — the wrapped summary), so
the user sees "Summary of earlier conversation:\n\n" followed by the
original system prompt with the actual summary appended later as a
synthetic system message. (See `notes/compact_agent_history.exs` —
the script ran with the wrong semantics on `overall-crawdad`.)

### 6. The AgentChannel crashes on `chat:compaction` broadcasts

`NestWeb.AgentChannel.handle_info/2` had no clause for
`{:chat_compaction, _}` — every channel would crash with
`FunctionClauseError` on every compaction broadcast. Fixed in the
previous round, but the fix only addresses the channel-side crash;
the broadcast still goes out from `Broadcasts.compaction/3` even
when the DB write fails.

### 7. Three different continuation shapes

`{:chat_continuation, _}`, `{:preflight_continuation, _}`,
`{:task_compaction_continuation, _}`. Each has its own failure
path with different semantics. The new chat task doesn't need to
know which one it was spawned by — the post-compaction state is
self-describing.

## Redesign

### Principle: compaction is owned by the Agent, not the chat task

The chat task is short-lived and single-shot. It makes LLM calls
and processes responses. When it needs compaction (preflight or
`context` tool's `compact` action), it signals "time for compaction"
to the Agent and exits. The Agent owns the compaction flow:

1. Ensures all in-memory messages are persisted.
2. Spawns the compactor.
3. On compactor success, spawns a NEW chat task with the
   post-compaction state.
4. On compactor failure, sets `status: :compaction_failed`,
   broadcasts `chat:error`, preserves the pending user message
   (and any other in-memory state), and waits for the user's
   retry.

The new chat task is independent of the old one. It reads the
post-compaction state and decides what to do:

- If `state.chat_state.pending_user_message` is non-nil: append
  it (with the right index) and make the LLM call.
- If the last assistant message has unsatisfied tool calls:
  synthesize tool results for them and make the LLM call.
- Otherwise: just make the LLM call.

### User message is appended exactly once

`handle_chat/3` stores the user message in
`state.chat_state.pending_user_message` (with `index: nil`).
It does NOT call `__append_message__/2`. We can't assign an index
until we know what compaction does to the message list.

The pending message is appended:

- After compaction succeeds, in the Agent's
  `compaction_done/3` handler, just before spawning the new chat
  task.
- If compaction isn't needed, in `handle_chat/3` itself, before
  spawning the chat turn.

### Compactor API: `{:ok, _} | {:error, _}`

`Compactor.compact/3` returns `{:ok, [Message.t()]} | {:error, term()}`.
The `:too_short` branch is `{:ok, messages}` (no-op). When the LLM
call returns empty (or non-string), the compactor returns
`{:error, :llm_returned_empty}`. No more synthetic
"[Summary of earlier conversation]" / "[Summary of recent work]"
placeholders — `wrap_summary/2` returns the raw LLM text. The
caller (the handler) extracts the summary text from position 1 of
the compactor's output (not position 0, which is the original
system prompt).

### Single failure path: `:compaction_failed`

`Compaction.spawn/5` sends one failure message:

```
{:compaction_failed, reason, continuation}
```

The Agent's handler routes by continuation shape to decide what to
do next. There's no need to store the continuation in
`state.chat_state` — the new chat task can derive everything it
needs from the post-compaction state.

### `:compaction_failed` is a frozen state

When compaction fails, the Agent:

1. Sets `status: :compaction_failed`, `cancelled: false`.
2. Broadcasts `chat:error` with the user-facing message.
3. Broadcasts `chat:status` so the UI reflects the new state.
4. Preserves `pending_user_message` (and any other in-memory state).
5. Does NOT spawn a new chat task. Does NOT send any messages to
   any chat task. The old chat task already exited.

The user can retry. The retry re-spawns the compactor. The
failure path is uniform across all three continuations.

### Channel rejects new messages while frozen

`chat:message` is rejected when the agent's status is
`"compacting"` or `"compaction_failed"`. Reply:
`{:error, %{"reason" => "agent_status_compacting"}}` or
`"agent_status_compaction_failed"`.

`chat:retry-compaction` is the only action accepted in
`"compaction_failed"` state. It sends `:retry_compaction` to the
Agent pid.

### Frontend: hide chat input, show retry button

When `status` is `"compacting"` or `"compaction_failed"`, the chat
input is replaced with a banner. When `"compaction_failed"`, the
banner carries a `Retry compaction` button (disabled in
`"compacting"`). The button calls
`channel.push("chat:retry-compaction", {})`.

## Edge case: multiple tool calls in the last agent response

When the LLM emits multiple tool calls in one response (e.g.,
`context.compact` plus another tool), the chat task persists the
assistant's response (with all tool calls) and the tool results
for the satisfied ones. Then it signals compaction. The state at
compaction time:

```
- assistant: T1 (some tool), T2 (context.compact)
- tool: R1 (T1's result)
```

After compaction:

```
- new system
- new summary
- assistant: T1, T2 (in renumbered_rest)
- tool: R1
```

T2 is unsatisfied. The new chat task synthesizes the tool result
for T2 (e.g., `"Compacted N messages into a summary..."`) and
appends it. The LLM sees T1 + R1 + T2 + synthesized R2 in the next
call.

If the last agent response is *really long* (lots of text plus
tool calls), the long text can be included in the compaction's
input (the compactor already sees it in `state.chat_state.messages`).
After compaction, the agent's handler can strip the long text from
the last assistant message before passing to the post-compaction
state. The new chat task reads the modified state and constructs
the LLM request.

For now, the primary implementation handles the simple case
(single unsatisfied `context.compact` tool call). The
multi-tool-call and long-response cases are noted as design
specifications for the test plan.

## Implementation outline

1. **`lib/nest/tokens/compactor.ex`**: change `compact/3` return
   type to `{:ok, _} | {:error, _}`. Remove the placeholder logic
   in `wrap_summary/2`. Update moduledoc.

2. **`lib/nest/agents/agent.ex`**:
   - Add `state.chat_state.pending_user_message` field.
   - In `handle_chat/3` (in `chat_pipeline.ex`): build the user
     message with `build_user_message/3`, store it in
     `pending_user_message` (no `__append_message__/2`). Decide
     whether to compact:
     - **No compaction**: append the pending message with
       `__append_message__/2`, then call `spawn_chat_turn(state)`.
     - **Compaction needed**: send `{:chat_needs_compaction,
       :preflight}` to self. The handler picks it up.
   - **New** `handle_info({:chat_needs_compaction, reason},
     state)`: log the reason, set `status: :compacting`,
     broadcast `chat:status`, spawn `Compaction.spawn/5` on
     `state.chat_state.messages`.
   - **New** `handle_info(:retry_compaction, state)`: if
     `status: :compaction_failed`, re-spawn `Compaction.spawn/5`
     on `state.chat_state.messages`. Set `status: :compacting`.
     Broadcast `chat:status`.

3. **`lib/nest/agents/agent/tool_loop.ex`**:
   `request_compaction_from_task/2` no longer waits for the
   compactor. It sends `{:chat_needs_compaction, :tool_compaction}`
   to the Agent and exits. The chat task process dies.

4. **`lib/nest/agents/agent/handlers/compaction_handler.ex`**:
   - On compactor success (`{:compaction_done, new_messages, _}`):
     - `regenerate_for_compaction/2`, `archive_and_compact/2`.
     - If `pending_user_message` is non-nil: append with
       `__append_message__/2`. Clear the field.
     - Spawn a new chat task with the post-compaction state (a
       new `spawn_post_compaction_chat_task/1` private helper).
     - Set `status: :streaming` (or `:idle` if the LLM returns a
       final answer on the next iteration).
   - On compactor failure (`{:compaction_failed, reason, _}`):
     - `Logger.warning`.
     - `Broadcasts.error/4` with the user-facing message.
     - `status: :compaction_failed`, `cancelled: false`.
     - `Broadcasts.status(state.name, state)`.
     - Preserve `pending_user_message`.
     - No further sends.

5. **`lib/nest/agents/agent/compaction.ex`**:
   - `Compaction.spawn/5`: on `{:ok, _}`, send
     `{:compaction_done, new_messages, continuation}`. On
     `{:error, reason}`, send `{:compaction_failed, reason,
     continuation}`.
   - Drop the `try/catch` and the old `send_failure/4`.

6. **`lib/nest_web/channels/agent_channel.ex`**:
   - `handle_in("chat:message", ...)`: reject when `agent.status
     in ["compacting", "compaction_failed"]`.
   - **New** `handle_in("chat:retry-compaction", _payload, socket)`:
     send `:retry_compaction` to the Agent pid.

7. **`lib/nest/agents.ex`**: **New** `retry_compaction/1`.

8. **Frontend**: hide chat input + show retry button when
   `status` is `"compacting"` or `"compaction_failed"`. Button
   enabled only when `"compaction_failed"`. Button calls
   `channel.push("chat:retry-compaction", {})`.

## Verification

- `mix precommit` clean.
- A failed compaction (stubbed LLM returns empty) puts the Agent
  in `:compaction_failed`. The chat page renders the retry
  button. Clicking it re-spawns the compactor. If the retry
  succeeds, the new chat task makes the LLM call. If it fails
  again, the Agent stays in `:compaction_failed`.

- A long pause between the failure and the retry works correctly:
  the compactor re-runs on the latest `state.chat_state.messages`
  (which preserves the user's pending message and any persisted
  in-flight tool results).

- The new chat task constructs the LLM request from the
  post-compaction state plus any synthesized tool result. The
  LLM sees a complete, coherent conversation.