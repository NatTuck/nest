# Extract compaction from the chat task; replace per-iteration preflight with deterministic tool-size accounting

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

Compaction currently happens in three places:

- **Trigger A (per-iteration):** `ChatTurn.Iteration.dispatch_preflight/2`
  fires at the start of every iteration of the chat task's
  `safe_iterate/1`, calling `ChatTurn.Preflight.run/1` which sends
  `{:preflight_request, self(), messages}` to the Agent. The Agent
  decides "fit" or "needs compaction" and replies.
- **Trigger B (per-handle_chat):** `ChatPipeline.maybe_compact_then_spawn/4`
  runs once when a `chat:message` arrives from the user.
- **Trigger C (LLM-driven):** The LLM emits a `context` tool call
  with `action: "compact"`, intercepted in `ToolLoop` via
  `request_compaction_from_task/2`.

This note describes the problems with the current flow and the
redesign that fixes them by:

1. **Removing per-iteration compaction** (Trigger A) entirely.
   The chat task's iteration loop becomes purely mechanical: receive
   an LLM response → run a batch preflight → execute tools →
   append → repeat.
2. **Making tool result sizes deterministic.** Each tool declares its
   output-size policy. The chat task's new `BatchSizer` module owns
   the preflight + execution + post-execution keep-or-summarize
   decision for `execute_command`.
3. **Restricting compaction to user-turn boundaries** (Trigger B)
   and the LLM-driven `context.compact` path (Trigger C). Both
   paths delegate to the Agent, which owns the compactor lifecycle.
4. **Keeping the doc's prior redesign** for compaction ownership:
   `pending_user_message`, `chat:retry-compaction`,
   `:compaction_failed` status, channel-side rejection, frontend
   retry UX — all unchanged.

## Current flow

### Trigger A: per-iteration preflight (to be removed)

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
to compact and either replies `:proceed` or spawns a `Compaction`
task with `{:preflight_continuation, task_pid}`. Compaction can fire
at any of the chat task's iterations, including inside a single
user-message's tool-call sequence.

### Streaming shortcut

Both Trigger A and Trigger B contain a `streaming_active?` shortcut
that replies `:proceed` if `state.chat_state.streaming_acc` is
non-empty (i.e., the LLM's response is still streaming in).
**This is forbidden under our constraint** ("never send an LLM
request whose message list predictably overflows"). Removal is part
of the redesign — the batch preflight only runs after
`streaming_acc` has been finalized into `state.chat_state.messages`.

### Trigger B: per-handle_chat preflight

`ChatPipeline.maybe_compact_then_spawn/4` runs once when `handle_chat/3`
is invoked from `chat:message`. Decides whether the user's incoming
message would exceed the context budget; if so, calls
`Compaction.spawn/5` with `{:chat_continuation, {content, mode}}`.

### Trigger C: `context.compact` tool action

When the LLM emits a tool call for the `context` tool with
`action: "compact"`, the chat task's `request_compaction_from_task/2`
sends `{:task_compaction_request, self(), focus}` to the Agent and
**blocks in a `receive`** for up to 60 seconds. The Agent spawns a
`Compaction` task with `{:task_compaction_continuation, task_pid}`.

### `context.compact` mid-batch (new constraint)

The LLM may emit `context.compact` as part of a batch with other
tools. Under the redesign, **`context.compact` must be the sole tool
in a batch.** If it appears with other tools, the entire batch is
refused (per-call synthetic error: "context.compact must be the sole
tool in a batch; reformulate"). The LLM retries with a singleton
batch. This keeps the batch preflight's post-state projection
unambiguous.

### Compactor (`Compaction.spawn/5`)

`Compaction.spawn/5` runs a `Task.Supervisor.start_child` that calls
`Nest.Tokens.Compactor.compact/3`. On `{:ok, _}` it sends
`{:compaction_done, new_messages, continuation}` to the Agent. On
`{:error, _}` it dispatches to one of two failure paths keyed by
the continuation shape (`{:chat_continuation, _}` or
`{:task_compaction_continuation, _}`). The third legacy shape
(`{:preflight_continuation, _}`) goes away.

## Problems with the current flow

### 1. The chat task waits synchronously for the compactor

`request_compaction_from_task/2` blocks the chat task in a `receive`
for up to 60 seconds. If the compactor fails and the user wants to
retry three weeks later, the chat task is already dead — the retry
can't continue its conversation.

Same problem with Trigger A's preflight path: the chat task blocks
in `Preflight.run/1` for up to 30 seconds. The redesign eliminates
Trigger A entirely — preflight only happens once per batch (after
the tools run, with actual sizes in hand) and once at user-turn
boundary (Trigger B).

### 2. The `chat_continuation` path silently corrupts state on failure

`Compaction.spawn/5`'s `send_failure/4` for `{:chat_continuation, _}`
sends `{:compaction_done, original_messages, continuation}` — the
original messages treated as if they were the compacted output.

### 3. The `chat_continuation` path appends the user message twice

`handle_chat/3` appends the user message via `__append_message__/2`.
On compactor success, `ChatPipeline.resume_after_compaction/3` calls
`__append_message__/2` *again* with a freshly-built user message.

### 4. The compactor emits literal placeholders

`Compactor.wrap_summary/2` produces `"[Summary of earlier conversation]"`
when the LLM returns empty, and wraps real summaries with
`"[Summary of earlier conversation]:\n\n<text>"`.

### 5. Three different continuation shapes

`{:chat_continuation, _}`, `{:preflight_continuation, _}`,
`{:task_compaction_continuation, _}`. Each has its own failure path.
The redesign collapses them to `{:chat_continuation, _}` and
`{:task_compaction_continuation, _}`; the third goes away with the
removal of Trigger A.

### 6. Heuristic tool-result truncation hides real overflow

`BudgetPlanner.execute/4` post-hoc truncates tool results that
exceed a per-call budget. The truncation is arbitrary (head cuts,
forward-reservation for skip responses, three-tier
keep/truncate/skip decision per tool). It does not guarantee the
cumulative post-batch state fits in `context_limit`. The new design
replaces this with deterministic size accounting: each tool's
output size is known after execution, the chat task projects the
post-batch state, and either keeps results in full or replaces
individual `execute_command` outputs with a deterministic summary.

### 7. Mid-iteration compaction races with streaming finalization

The `streaming_active?` shortcut in Trigger A lets the chat task
proceed with an LLM call while the previous iteration's
`streaming_acc` is still mutating. This can result in an LLM
request whose message list predictably overflows or whose index
accounting is broken (deltas from the still-streaming message
collide with later compaction's renumbered indices).

## Redesign

### Principle: compaction is owned by the Agent

Compaction can only fire at user-turn boundaries (Trigger B) or via
LLM-driven `context.compact` calls (Trigger C). The chat task never
triggers compaction mid-sequence. Within a user turn (the LLM
iteration loop driven by tool calls), the loop is purely mechanical.

When compaction is needed (Trigger B or C), the chat task signals
"time for compaction" to the Agent and exits. The Agent owns the
compaction flow:

1. Ensures all in-memory messages are persisted.
2. Spawns the compactor.
3. On compactor success, spawns a NEW chat task with the
   post-compaction state.
4. On compactor failure, sets `status: :compaction_failed`,
   broadcasts `chat:error`, preserves the pending user message
   (and any other in-memory state), and waits for the user's
   retry via `chat:retry-compaction`.

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
placeholders — `wrap_summary/2` returns the raw LLM text. The caller
(handler) extracts the summary text from position 1 of the
compactor's output.

### Single failure path: `:compaction_failed`

`Compaction.spawn/5` sends one failure message:

```
{:compaction_failed, reason, continuation}
```

The Agent's handler routes by continuation shape to decide what to
do next.

### `:compaction_failed` is a frozen state

When compaction fails, the Agent:

1. Sets `status: :compaction_failed`, `cancelled: false`.
2. Broadcasts `chat:error` with the user-facing message.
3. Broadcasts `chat:status` so the UI reflects the new state.
4. Preserves `pending_user_message` (and any other in-memory state).
5. Does NOT spawn a new chat task. Does NOT send any messages to
   any chat task. The old chat task already exited.

The user can retry. The retry re-spawns the compactor. The
failure path is uniform across both continuations.

### Channel rejects new messages while frozen

`chat:message` is rejected when the agent's status is `"compacting"`
or `"compaction_failed"`. Reply:
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

## Tool size policies

This section is the core of the redesign. Each tool's output size
must be deterministic so the BatchSizer can project the post-batch
message list before the next LLM call is made.

### Per-tool sizing

| Tool | Pre-batch projection | Post-execution |
|------|----------------------|----------------|
| `read_file` | Stat-then-cap (100 MB). If under: `File.read` → `Estimator.estimate(content)` exact. If over: refuse batch. | Always kept full. |
| `execute_command` | Empty summary baseline + 20% padding (`Estimator.estimate(empty_line_1) * 1.20`). | Sequential keep-or-summarize (see below). |
| `context` (action: "check") | `Estimator.estimate("Context: N messages, ~X / Y tokens (Z%)")` with N, X, Y, Z substituted. | Always kept (call-result string already bounded). |
| `context` (action: "compact") | Special: not subject to BatchSizer; `ToolLoop` intercepts. | Not a normal tool result. |
| `write_file` | `Estimator.estimate("Successfully wrote N bytes to <path>.")` (or the bounded error message). | Always kept. |
| `edit` | `Estimator.estimate("Replaced N occurrence(s) in <path>.")` (or the bounded error). | Always kept. |
| `inspect_file` | `Estimator.estimate(<full report>)` after running the `file -- <path>` and stats queries. The format is deterministic, only path and stats vary. | Always kept. |

The `context.tool` with `action: "compact"` is intercepted in
`ToolLoop` before the BatchSizer runs. If the batch contains
`context.compact` with other tools, the entire batch is refused.
If `context.compact` is alone, the existing
`request_compaction_from_task/2` flow runs unchanged.

### `read_file` implementation

Replaces the current `ShellCmd.execute("cat -- ...")` with a direct
`File.read/1`. Stat-then-cap matching `InspectFile`'s 100 MB cap:

```
stat = File.stat(path)
if {:ok, %{size: s}} when s <= 100_000_000 → File.read(path) and estimate.
else → {:error, "File too large; use shell_cmd ..."}.
```

The cap is by bytes. The estimator (cl100k_base + 20% safety
multiplier) translates bytes to tokens. The LLM's `inspect_file` is
the proper preflight for large files; `read_file` assumes the LLM
has already inspected.

### `execute_command` implementation

`ShellCmd.execute/5` (or its renamed `execute_command` equivalent)
runs the command unchanged. The tool does *not* do its own
summarization — the BatchSizer owns the keep-or-summarize decision
after the command returns. The tool returns `{:ok, full_output}`
or `{:error, full_output}`; the BatchSizer decides what to keep.

Other tools (`write_file`, `edit`, `inspect_file`) likewise return
their full result; the BatchSizer applies `Estimator.estimate/1` to
compute the actual charge.

## BatchSizer: preflight + execute + sequential decide

A new module `Nest.Agents.Agent.BatchSizer` (in
`lib/nest/agents/agent/batch_sizer.ex`) replaces the current
`BudgetPlanner.execute/4` path inside `ToolLoop.execute/3`.

### Public API

```
@spec run([ToolCall.t()], ctx :: map()) ::
  {:ok, [ToolResult.t()]} |                # batch ran; results ready to append
  {:refuse, [ToolResult.t()]}              # batch refused; ToolResults are synthetic errors
def run(tool_calls, ctx)
```

`ctx` carries messages, context_limit, tools list, agent_pid, and
agent_tmp_path (the per-agent temp directory).

### Three phases

#### Phase 1: Preflight (before any tool runs)

1. Inspect the batch for `context.compact`. If present with other
   tools: refuse the entire batch with per-call synthetic errors.
   If alone: defer to `ToolLoop.request_compaction_from_task/2`
   (special handling — bypasses BatchSizer).
2. Project each tool's minimum size using its sizing policy.
3. For `read_file`: do `File.stat` and `File.read` to get the
   exact size. If file > 100 MB, refuse the batch.
4. Sum: `current_messages_size + Σ(proj_sizes) + @preflight_reserve`.
5. If `> context_limit`: refuse batch.
6. Else: proceed to execution.

The 20% padding for `execute_command` is included in the
projection; once actual sizes are known post-execution, the
post-execution step reconciles.

#### Phase 2: Execute all tools

Run all remaining tools. Each tool returns its full result; sizes
are computed via `Estimator.estimate/1` (for text results) or via
the tool's policy (e.g., `read_file` already returned the exact
size from Phase 1).

`write_file`, `edit`, `inspect_file`, `context` (check) — all keep
their full content. No branch logic in the post-execution step.

#### Phase 3: Sequential keep-or-summarize (only `execute_command`)

For each `execute_command` result, in batch order, build a
`running_total` of all tool sizes appended so far (plus the
pre-batch current size plus `@preflight_reserve`).

For each `execute_command` result:

- If `running_total + Estimator.estimate(full_output) ≤ context_limit`:
  keep full. Charge `Estimator.estimate(full_output)`.
- Else: write `full_output` to
  `<agent_tmp_path>/<random>.txt` (autocleaned at agent
  termination). Build the deterministic summary (see below). Charge
  `summary_size = Estimator.estimate(assembled_summary)`.

The post-execution sum is guaranteed to fit because the preflight
padded `execute_command` projections (Phase 1) were inflated by 20%,
and Phase 3 either keeps (smaller than inflated projection) or
summarizes (matches inflated projection up to actual size).

### Summary template (execute_command)

```
Command output of '<command>' (<N> tokens) saved to <path>.

<first M tokens of output, where M is derived from remaining summary budget>
```

- Line 1 size: `Estimator.estimate(format_with_command_N_path)`.
  Both `command` and `N` are variable; the format string is fixed.
- Line 3 size: `Estimator.estimate(<head text>)`.
- `head` is selected by walking the actual output line-by-line and
  taking as many lines as fit in the remaining summary budget
  (`head_budget = remaining_for_this_summary` minus the line-1
  size). M is derived from the output and budget — no hardcoded
  constant.

The summary is computed by the BatchSizer from the format, the
command string, the path, and the head text. Its size is whatever
`Estimator.estimate/1` returns for the assembled text. No
hardcoded constants exist anywhere.

### Output: ready-to-append results

`run/2` returns `[%ToolResult{...}]` in batch order. Some entries
may be synthetic errors (batch refused), some may be full output,
some may be the `<path>`-and-head summary. The chat task's
`spawn_tool_worker` appends each via `__append_message__/2` and
proceeds to the next iteration without further preflight (the
BatchSizer's running_total already accounts for everything).

### Streaming deferral

The BatchSizer runs only after the chat task's iteration has
received the LLM's response and `streaming_acc` has been finalized
into a normal `Assistant` message in `state.chat_state.messages`.
The chat task waits for this in its existing iteration loop
(`safe_iterate/1`'s `:get_messages_with_cancelled` call returns
once the Agent's finalize handler completes).

### Single-flight in the chat task

Within a single chat task, only one LLM-call → BatchSizer sequence
is in flight at a time. The chat task's `safe_iterate/1` only
continues to the next iteration after `{:tool_results, _}` is
received from the tool worker. This is unchanged from current
behavior; the BatchSizer's three-phase flow runs inside the existing
tool worker.

## Edge case: multiple tool calls in one assistant response

The LLM may emit multiple tool calls in one assistant message (e.g.,
`read_file_1`, `read_file_2`, `execute_command_1`). The BatchSizer
handles the batch atomically: a single preflight, a single
execution, a single sequential decide pass. If any one tool in the
batch would refuse (e.g., `read_file` over cap), the whole batch is
refused.

`context.compact` is never co-batched. If present, it must be the
sole tool in the batch, and is handled by the existing special
flow.

If multiple `execute_command`s share a batch and one exceeds the
running budget, only that one is summarized; earlier ones in the
batch order are kept full because the budget allows them.

## Implementation outline

1. **`lib/nest/agents/agent/batch_sizer.ex`** (new):
   - `BatchSizer.run/2` implements Phase 1 + Phase 2 + Phase 3.
   - `BatchSizer.summarize/4` builds the summary template and
     computes its actual size via `Estimator`.
   - `BatchSizer.project_size/2` returns the pre-batch projection
     for a single tool call (delegates to the tool's policy).

2. **`lib/nest/agents/agent/tool_loop.ex`**:
   - `execute/3` delegates entirely to `BatchSizer.run/2`.
   - `context.compact` interception stays here — runs *before*
     BatchSizer and either handles the solo batch via
     `request_compaction_from_task/2` or refuses the multi-tool
     batch.

3. **`lib/nest/agents/agent/chat_turn/iteration.ex`**:
   - `Iteration.dispatch_preflight/2` replaced with
     `Iteration.dispatch_batch/2`. No GenServer round-trip; just
     spawns the tool worker which calls BatchSizer.

4. **`lib/nest/agents/agent/chat_turn.ex`**:
   - `safe_iterate/1`'s call to `Iteration.dispatch_preflight`
     updates to `Iteration.dispatch_batch`.

5. **`lib/nest/agents/agent/handlers/compaction_handler.ex`**:
   - `preflight_request/3` clause removed.
   - `task_compaction_request/3`, `task_compaction_done/3`,
     `compaction_done/3`, `compaction_failed_for_preflight/3`
     remain unchanged.
   - Continuation shapes: only `{:chat_continuation, _}` and
     `{:task_compaction_continuation, _}` survive.

6. **`lib/nest/tools.ex`** and **`lib/nest/tools/inspect_file.ex`**:
   - `read_file_function/2` replaces `ShellCmd.execute("cat -- ...")`
     with direct `File.read` + `Estimator.estimate`.
   - `inspect_file`'s stat-then-cap pattern (`@max_bytes =
     100_000_000`) is mirrored by `read_file`.
   - `execute_command`'s function (`function: fn ... -> ShellCmd.execute(...)` )
     unchanged in form; only the BatchSizer owns the keep-or-summarize
     decision post-execution.

7. **`lib/nest/tokens/budget_planner.ex`** — deleted.
8. **`lib/nest/tokens/skip_response.ex`** — deleted.
9. **`lib/nest/tokens/truncate.ex`** — deleted (the summary template
   in BatchSizer is the only "reduction" path for `execute_command`,
   and it's deterministic).

10. **`lib/nest/llm/tool.ex`** — unchanged. The function signature
    stays `{:ok | :error, content}`.

11. **Tests**:
    - **NEW: `test/nest/agents/batch_sizer_test.exs`** — covers
      BatchSizer's decision branches.
    - **`test/nest/agents/agent_compaction_test.exs`** — invert the
      `"preflight_request with active streaming returns :proceed"`
      test (the constraint says preflight must not skip while
      streaming). Add: `"BatchSizer refuses single tool batch that
      would overflow"`, `"BatchSizer keeps execute_command full
      when budget allows"`, `"BatchSizer summarizes
      execute_command when budget forces it"`,
      `"BatchSizer summary size is Estimator-computed, no
      hardcoded constant"`.
    - Add tests for `read_file` stat-then-cap (refusal at 100 MB,
      exact sizing below cap), `inspect_file` size projection,
      `write_file`/`edit` size projections, `context.check` size
      projection, `context.compact` co-batch refused.

12. **`lib/nest/agents/agent.ex`** — add
    `state.chat_state.pending_user_message` field (per the doc's
    prior redesign); unchanged otherwise.

13. **`lib/nest_web/channels/agent_channel.ex`**: reject
    `chat:message` while compacting/`:compaction_failed`; add
    `chat:retry-compaction` handler (per the doc's prior redesign).
14. **`lib/nest/agents.ex`**: new `retry_compaction/1` (per the
    doc's prior redesign).
15. **Frontend**: hide chat input + show retry button when status
    is `"compacting"` or `"compaction_failed"` (per the doc's prior
    redesign).

## Verification

- `mix precommit` clean (credo, biome, format).
- `mix test` under 10 seconds; existing tests + BatchSizer tests
  pass.
- New test file alone targets line coverage of `BatchSizer.run/2`'s
  three phases.
- Tool sizing tests:
  - `read_file` (stat-then-cap; exact sizing within cap).
  - `execute_command` (empty-summary preflight projection;
    keep-or-summarize decision across budget boundaries).
  - `write_file`/`edit`/`inspect_file`/`context.check` (sizing
    projections are Estimator-computed; matches actual result).
- Existing `agent_compaction_test.exs`'s streaming-bypass test is
  inverted, not deleted (the constraint is still binding).
- The doc's verification section absorbs: "execute_command results
  longer than budget can fit are replaced with a path-and-head
  summary whose size is computed from the format via Estimator
  (no hardcoded summary_tokens constant)."

## Out of scope (carried over from prior doc)

- `:compaction_failed` Agent status, `chat:retry-compaction`
  channel handler, frontend retry UX, `pending_user_message`
  mechanism — all unchanged from the doc's prior redesign.
- The doc's "long assistant response" trim-mid-stream concern
  remains a future item; under the redesign, an extremely long
  assistant message simply becomes a very-large assistant message
  in `state.chat_state.messages`, and the next batch's preflight
  refuses or summarize-decides around it.
