# Extract compaction from the chat task; replace per-iteration preflight with deterministic tool-size accounting

## Implementation status

The BatchSizer core is landed and all existing tests pass (`mix precommit`
clean, 771 tests, 0 failures). The remaining work is the compaction-
ownership half of the prior redesign — the parts of the doc that
deal with what happens *if* compaction fires (Trigger B / Trigger C
paths), not whether compaction fires.

**Done (BatchSizer core):**

- `lib/nest/agents/agent/batch_sizer.ex` — new module: preflight →
  execute → keep-or-summarize for tool batches.
- `lib/nest/agents/agent/tool_loop.ex` — `execute/3` delegates to
  `BatchSizer.run/2`; `context.compact` solo routes through the
  existing `request_compaction_from_task/2`; `context.compact`
  co-batched with other tools refuses the entire batch.
- `lib/nest/agents/agent/chat_turn/iteration.ex` — `dispatch_preflight/2`
  replaced with `dispatch_batch/2` (no compaction trigger).
- `lib/nest/agents/agent/chat_turn.ex` — `safe_iterate/1` calls
  `dispatch_batch`.
- `lib/nest/agents/agent/chat_pipeline.ex` — `tmp_path` added to the
  chat turn's `ctx` (used as BatchSizer's per-agent temp directory).
- `lib/nest/agents/agent/handlers/compaction_handler.ex` —
  `preflight_request/3`, `compaction_failed_for_preflight/3`, and the
  `{:preflight_continuation, _}` route in `compaction_done/3` removed.
- `lib/nest/agents/agent/compaction.ex` — `{:preflight_continuation, _}`
  removed from typespec and `send_failure/4`.
- `lib/nest/agents/agent/chat_turn/preflight.ex` — deleted.
- `lib/nest/tools.ex` — `read_file` now `File.stat` + `File.read`
  (was `ShellCmd.execute("cat -- ...")`). 100 MB cap matches
  `inspect_file`; UTF-8 validation on read content; bounded error
  strings for failure modes.
- `lib/nest/tokens/budget_planner.ex`, `lib/nest/tokens/skip_response.ex`,
  `lib/nest/tokens/truncate.ex` — deleted (heuristic-shrink paths
  gone; deterministic BatchSizer replaces them).
- `test/nest/agents/agent/batch_sizer_test.exs` — 18 new tests
  covering all three phases + ToolLoop integration.
- `test/nest/agents/agent_compaction_test.exs` — the streaming-bypass
  tests are inverted to assert the new contract (no
  `preflight_request` handler; no `streaming_acc` consult).
- `test/nest/agents/agent/chat_turn_structure_test.exs` — structural
  invariant inverted: now asserts no `preflight_request` literal in
  the iteration code and that `Iteration.dispatch_batch/2` exists.
- `test/nest/tools_test.exs` — "no such file" string updated.
- `test/nest/agents/agent_compaction_chat_continuation_test.exs` —
  spurious init-time `:agent_not_found` warning fixed (insert agent
  row before `start_supervised!`).

**TODO (compaction ownership; see "TODO" section at end of doc):**

- `pending_user_message` Agent field plumbing.
- Unify compaction failure path (single `{:compaction_failed, reason, _}`
  from `Compaction.spawn/5`).
- `:compaction_failed` Agent status (set on failure; broadcast
  `chat:error`; preserve `pending_user_message`).
- `Compactor.compact/3` API: `{:ok | :error, _}` (no synthetic
  placeholders).
- `chat:retry-compaction` channel handler + reject `chat:message`
  in compacting/`:compaction_failed` states.
- `lib/nest/agents.ex` `retry_compaction/1`.
- Frontend: hide chat input + show retry button when status is
  `"compacting"` or `"compaction_failed"`.

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

Compaction fires in two of the three historical places (the third,
per-iteration preflight, has been removed — see "Prior flow" below
for context):

- **Trigger B (per-handle_chat):** `ChatPipeline.maybe_compact_then_spawn/4`
  runs once when a `chat:message` arrives from the user.
- **Trigger C (LLM-driven):** The LLM emits a `context` tool call
  with `action: "compact"`, intercepted in `ToolLoop` via
  `request_compaction_from_task/2`.

This doc describes the problems with the prior flow and the
redesign that fixes them. The redesign has two halves:

1. **Tool size accounting (LANDED).** Per-iteration preflight (Trigger
   A) is gone. The chat task's iteration loop is now purely
   mechanical: receive an LLM response → run a deterministic
   preflight on the planned tool calls (using each tool's sizing
   policy) → execute tools → apply sequential keep-or-summarize for
   `execute_command` → append → repeat. All sizing is computed via
   `Nest.Tokens.Estimator`; no heuristic truncation survives.

2. **Compaction ownership (TODO — see "TODO" section at end).** Even
   with #1, compaction can still fire at user-turn boundaries
   (Trigger B) or via `context.compact` (Trigger C). The Agent
   owns that flow end-to-end: `pending_user_message` (one-shot
   append), single `{:compaction_failed, reason, _}` failure
   contract, `:compaction_failed` Agent status, channel-side
   rejection, frontend retry UX.

## Prior flow

This section describes the pre-rewrite flow for context — why each
of the redesign's two halves exists. Trigger A and the streaming
shortcut have been removed; Triggers B and C remain.

### Trigger A: per-iteration preflight (removed)

**Status:** removed. Code is gone from the tree
(`lib/nest/agents/agent/chat_turn/preflight.ex` deleted;
`Iteration.dispatch_preflight/2` replaced by `dispatch_batch/2`;
`CompactionHandler.preflight_request/3` clause removed).

**What it did:** every iteration of the chat task started with a
preflight check:

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

The Agent's `CompactionHandler.preflight_request/3` decided whether
to compact and either replied `:proceed` or spawned a `Compaction`
task with `{:preflight_continuation, task_pid}`. Compaction could
fire at any iteration of the chat task, including mid-sequence
inside a single user-message's tool-call chain.

### Streaming shortcut (removed)

**Status:** removed. The `streaming_active?` shortcut that replied
`:proceed` while `state.chat_state.streaming_acc` was non-empty is
gone — the BatchSizer's preflight runs only after `streaming_acc`
has been finalized into a normal `Assistant` message in
`state.chat_state.messages`. This preserves the constraint
("never send an LLM request whose message list predictably
overflows") without the streaming-race escape hatch.

### Trigger B: per-handle_chat preflight

**Status:** still active. `ChatPipeline.maybe_compact_then_spawn/4`
runs once when `handle_chat/3` is invoked from `chat:message`.
Decides whether the user's incoming message would exceed the
context budget; if so, calls `Compaction.spawn/5` with
`{:chat_continuation, {content, mode}}`. The bug-fix work for this
trigger (single failure path, `pending_user_message` plumbing) is
TODO 2 + TODO 4 in the "TODO" section.

### Trigger C: `context.compact` tool action

**Status:** still active. When the LLM emits a tool call for the
`context` tool with `action: "compact"`, the chat task's
`request_compaction_from_task/2` sends `{:task_compaction_request,
self(), focus}` to the Agent and **blocks in a `receive`** for up
to 60 seconds. The Agent spawns a `Compaction` task with
`{:task_compaction_continuation, task_pid}`. Single-failure-path
fix for this trigger is TODO 2.

### `context.compact` mid-batch (constraint)

The LLM may emit `context.compact` as part of a batch with other
tools. **`context.compact` must be the sole tool in a batch.** If
it appears with other tools, the entire batch is refused (per-call
synthetic error: "context.compact must be the sole tool in a batch;
reformulate"). The LLM retries with a singleton batch. This is
enforced in `BatchSizer.preflight/2` and keeps the BatchSizer's
post-state projection unambiguous.

### Compactor (`Compaction.spawn/5`)

`Compaction.spawn/5` runs a `Task.Supervisor.start_child` that calls
`Nest.Tokens.Compactor.compact/3`. On `{:ok, _}` it sends
`{:compaction_done, new_messages, continuation}` to the Agent. On
`{:error, _}` it dispatches to one of two failure paths keyed by
the continuation shape (`{:chat_continuation, _}` or
`{:task_compaction_continuation, _}`). The third legacy shape
(`{:preflight_continuation, _}`) is gone.

## Problems with the prior flow

The redesign addresses seven problems. The first three are fully
resolved by the BatchSizer rewrite. The remaining four (1, 2, 3, 4
of the "TODO" section) are still open.

### 1. The chat task waits synchronously for the compactor

`request_compaction_from_task/2` blocks the chat task in a `receive`
for up to 60 seconds. If the compactor fails and the user wants to
retry three weeks later, the chat task is already dead — the retry
can't continue its conversation.

The pre-BatchSizer flow had the same problem at Trigger A: the
chat task blocked in `Preflight.run/1` for up to 30 seconds. Trigger
A is removed; the chat task now never blocks waiting on a compaction
decision mid-iteration.

Trigger C (`request_compaction_from_task/2`) still blocks. The
Agent-owns-the-compactor redesign addresses this: the chat task
exits when it signals "time for compaction," and a new chat task is
spawned post-compaction (TODO 2/3).

### 2. The `chat_continuation` path silently corrupts state on failure

`Compaction.spawn/5`'s `send_failure/4` for `{:chat_continuation, _}`
sends `{:compaction_done, original_messages, continuation}` — the
original messages treated as if they were the compacted output.
**This bug is still present.** TODO 2 in the "TODO" section fixes
it.

### 3. The `chat_continuation` path appends the user message twice

`handle_chat/3` appends the user message via `__append_message__/2`.
On compactor success, `ChatPipeline.resume_after_compaction/3` calls
`__append_message__/2` *again* with a freshly-built user message.
**Still present.** TODO 4 fixes it via `state.chat_state.pending_user_message`.

### 4. The compactor emits literal placeholders

`Compactor.wrap_summary/2` produces `"[Summary of earlier conversation]"`
when the LLM returns empty, and wraps real summaries with
`"[Summary of earlier conversation]:\n\n<text>"`. **Still present.**
TODO 1 fixes it: `Compactor.compact/3` returns
`{:error, :llm_returned_empty}` and `wrap_summary/2` passes raw LLM
text through unchanged.

### 5. Three different continuation shapes

**Resolved.** The third shape (`{:preflight_continuation, _}`) is
gone. Two remain (`{:chat_continuation, _}` and
`{:task_compaction_continuation, _}`); their failure paths will be
unified under TODO 2.

### 6. Heuristic tool-result truncation hides real overflow

**Resolved.** `BudgetPlanner.execute/4` is deleted (with
`lib/nest/tokens/budget_planner.ex`, `skip_response.ex`, and
`truncate.ex`). Replaced by `Nest.Agents.Agent.BatchSizer` with
deterministic size accounting: each tool's output size is known
after execution (via `Nest.Tokens.Estimator`), the BatchSizer
projects the post-batch state, and either keeps results in full or
replaces individual `execute_command` outputs with a deterministic
summary.

### 7. Mid-iteration compaction races with streaming finalization

**Resolved.** The `streaming_active?` shortcut is gone. The
BatchSizer's preflight runs only after `streaming_acc` has been
finalized into `state.chat_state.messages`.

## Redesign

This section describes the target state of the redesign. The
tool-size-accounting half is in the tree today (see "Implementation
status"); the compaction-ownership half is the contract that TODO
items 1-9 land. The two halves are presented together here for
reference.

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
The `:too_short` branch and the successful-run branch both return
`{:ok, messages}` — the no-op case is structurally identical to the
compact case, and callers that care can detect it by comparing
lengths. When the LLM call returns empty (or non-string), the
compactor returns `{:error, :llm_returned_empty}`. The `llm_call_fn`
callback signature also changes from `([Message.t()] -> String.t())`
to `([Message.t()] -> {:ok, String.t()} | {:error, term()})` so
transport-level errors propagate. No more synthetic "[Summary of
earlier conversation]" / "[Summary of recent work]" placeholders —
`wrap_summary/2` returns the raw LLM text. The caller (handler)
extracts the summary text from position 1 of the compactor's output.

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

### Tool-result cap (`max_result_tokens`)

The BatchSizer also enforces a per-batch inline-vs-summary cap on
tool results. The LLM may pass `max_result_tokens` in a tool call's
arguments to ask for a tighter cap; the BatchSizer treats this as a
**gate** (does the result fit inline, or do we route it?), never a
**shrinker** (we never truncate a result to fit).

**Formula** (computed once per batch in `BatchSizer.run/2`):

```
usable       = context_limit - estimate_messages(messages) - @preflight_reserve
default_cap  = floor(usable * 0.80)
effective_cap = min(LLM_override, default_cap)   # LLM may only lower
```

When `context_limit: nil`, no cap is enforced
(degraded-but-hopeful path).

**Per-tool behavior when the cap is exceeded:**

| Tool | Cap exceeded action |
|------|---------------------|
| `execute_command` | Write full output to `<tmp>/exec-<rand>.txt`. Return `Command output of '<cmd>' (<N> tokens) saved to <path>.\n\n<head>` inline. |
| `read_file` | Return `{:error, "File is X tokens which exceeds your requested limit of Y."}` (LLM gets a structured error with the actual vs. requested counts). |
| `write_file` / `edit` / `context` / `inspect_file` | Log warning, keep full. Cap is unreachable in practice (these tools return bounded output by construction). |

**Decision tree in `apply_one_with_acc/3`:**

```
1. full_size = Estimator.estimate(content) + per_message_overhead()

2. If cap is set and full_size > cap:
     Per-tool routing (see table above). For execute_command this
     reuses the existing summary path; for read_file this returns
     a structured error; for others we keep full with a warning.

3. Else (content fits the inline cap):
     If keep_full?(tc, acc, full_size):
       Return full content
     Else (rare — batch budget overflow post-preflight):
       Same per-tool routing (execute_command → summary, others → log + full).
```

**Two principles, no compromises:**

1. **No truncations** — the LLM never sees a partially-degraded tool
   result. Either full content or a summary pointing to a tmp file,
   or an explicit error with the size counts.
2. **No overflows** — the BatchSizer's preflight guarantees space
   for the minimum size of every tool call in the batch *before*
   any tool runs (via `summary_baseline_size() * @safety_padding`
   for `execute_command`). The cap is the inline-vs-summary
   threshold, not a sizing guarantee.

The cap is **static per batch** (computed once in `run/2`,
threaded through `cook` via `acc.usable`). Prior tools in the
batch do not shrink later tools' caps.

**Removal of per-tool defaults:** the legacy `Tool` struct carried
a per-tool `max_result_tokens` field. That field is gone — tool
caps are owned by the BatchSizer, not by individual tool builders.
The JSON schema still advertises `max_result_tokens` on every
tool so the LLM can request a tighter cap on a per-call basis,
but the actual default is global (80% of remaining usable) rather
than per-tool.

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

> Each item is marked **[x]** (done) or **[ ]** (TODO). The TODO
> items are listed again with full detail in the "TODO" section at
> the end. Items 12-15 are the original outline's remaining work;
> the TODO section adds three Compactor/Compaction-spawn fixes
> (TODOs 1-3), one test-cleanup item (TODO 9), and splits the
> frontend item (15) into a JS wiring half (TODO 6) and a UI banner
> half (TODO 8).

1. **[x]** **`lib/nest/agents/agent/batch_sizer.ex`** (new):
   - `BatchSizer.run/2` implements Phase 1 + Phase 2 + Phase 3.
   - `BatchSizer.summarize/4` became `build_summary_with_size/4`
     (private helper inside the module; integrates size computation).
   - `BatchSizer.project_size/2` is inlined as `projected_size/2`
     (matched on `name`, dispatches per-tool).

2. **[x]** **`lib/nest/agents/agent/tool_loop.ex`**:
   - `execute/3` delegates to `BatchSizer.run/2` for general batches.
   - Solo `context.compact` routes through `request_compaction_from_task/2`.
   - `context.compact` co-batched with other tools refuses the entire
     batch with per-call synthetic errors.

3. **[x]** **`lib/nest/agents/agent/chat_turn/iteration.ex`**:
   - `dispatch_preflight/2` replaced with `dispatch_batch/2`.

4. **[x]** **`lib/nest/agents/agent/chat_turn.ex`**:
   - `safe_iterate/1` calls `Iteration.dispatch_batch`.

5. **[x]** **`lib/nest/agents/agent/handlers/compaction_handler.ex`**:
   - `preflight_request/3` clause removed.
   - `compaction_failed_for_preflight/3` removed.
   - `{:preflight_continuation, _}` route in `compaction_done/3`
     removed.
   - `task_compaction_request/3`, `task_compaction_done/3`,
     `compaction_done/3` (with only `chat_continuation` and
     `task_compaction_continuation` continuations) unchanged.
   - **TODO:** `compaction_done/3`'s `chat_continuation` path
     still resumes via `ChatPipeline.resume_after_compaction/3`
     even when compactor returned `{:error, _}`. See TODO 2.

6. **[x]** **`lib/nest/tools.ex`** and **`lib/nest/tools/inspect_file.ex`**:
   - `read_file_function/2` replaced `ShellCmd.execute("cat -- ...")`
     with direct `File.stat` + `File.read` (+ UTF-8 validation).
   - Stat-then-cap pattern (`@max_read_file_bytes = 100_000_000`)
     mirrors `InspectFile`'s `@max_bytes`.
   - `execute_command`'s function unchanged; BatchSizer owns the
     keep-or-summarize decision post-execution.

7. **[x]** **`lib/nest/tokens/budget_planner.ex`** — deleted.
8. **[x]** **`lib/nest/tokens/skip_response.ex`** — deleted.
9. **[x]** **`lib/nest/tokens/truncate.ex`** — deleted.

10. **[x]** **`lib/nest/llm/tool.ex`** — function signature unchanged
    (`{:ok | :error, content}`). Docstring updated to reference
    BatchSizer.

11. **[x]** **Tests**:
    - **NEW: `test/nest/agents/agent/batch_sizer_test.exs`** — 18
      tests covering preflight, execute, keep-or-summarize,
      read_file integration, and ToolLoop routing.
    - **`test/nest/agents/agent_compaction_test.exs`** — streaming-bypass
      tests inverted to assert no `preflight_request` handler.
    - **`test/nest/agents/agent/chat_turn_structure_test.exs`** —
      structural invariant inverted.
    - **`test/nest/tools_test.exs`** — "no such file" string updated.
    - **`test/nest/agents/agent_compaction_chat_continuation_test.exs`** —
      spurious init-time warning fixed.

12. **[ ]** **`lib/nest/agents/agent.ex`** — TODO. Add
    `state.chat_state.pending_user_message` field. See TODO 4.

13. **[ ]** **`lib/nest_web/channels/agent_channel.ex`** — TODO.
    Reject `chat:message` while compacting/`:compaction_failed`;
    add `chat:retry-compaction` handler. See TODO 5, 6.

14. **[ ]** **`lib/nest/agents.ex`** — TODO. Add `retry_compaction/1`.
    See TODO 7.

15. **[ ]** **Frontend** — TODO. Hide chat input + show retry button
    when status is `"compacting"` or `"compaction_failed"`. See
    TODO 8.

## Verification

The BatchSizer half of the redesign is verified by the following
checks. All are expected to pass before marking this work done.

### Precommit + full test suite

```
mix precommit           # credo, biome, format, dialyzer, docs
mix test                # under 10s; ~770 tests, 0 failures
```

### BatchSizer tests in isolation

```
mix test test/nest/agents/agent/batch_sizer_test.exs
```

The 18 tests cover Phase 1 (preflight), Phase 2 (execute),
Phase 3 (keep-or-summarize for `execute_command`), `read_file`
stat-then-cap integration, and ToolLoop routing
(`context.compact` solo / co-batched).

### Tool sizing tests

- `read_file` — stat-then-cap; exact sizing within cap.
- `execute_command` — empty-summary preflight projection (with 20%
  padding); keep-or-summarize decision across budget boundaries;
  summary path-and-head assembled from the format string + actual
  head text (no hardcoded `summary_tokens` constant).
- `write_file`, `edit`, `inspect_file`, `context.check` — sizing
  projections are `Estimator`-computed; matches actual result.

### Behavioral assertions

- `mix test test/nest/agents/agent/chat_turn_structure_test.exs` —
  `Iteration.dispatch_batch/2` exists; `preflight_request` literal
  absent from iteration code; `lib/nest/agents/agent/chat_turn/preflight.ex`
  file absent.
- `mix test test/nest/agents/agent_compaction_test.exs` —
  streaming-bypass tests inverted (asserts no `preflight_request`
  handler; structural assertion that handler doesn't consult
  `streaming_acc`).
- `mix test test/nest/tools_test.exs` — `read_file` returns
  "File not found" rather than the prior `ShellCmd.execute` error
  string.
- `mix test test/nest/agents/agent_compaction_chat_continuation_test.exs`
  — runs without spurious `:agent_not_found` log warning.

### Compile-time checks

`mix compile --warnings-as-errors` must remain clean. In
particular, `BatchSizer`'s `apply_one_with_acc/3` must not
shadow-bind the `running` accumulator across map-reduce iterations;
the existing 20%-padding math for `execute_command` must produce
exactly the `summary_baseline_size * 1.20` projection.

### What this verification does NOT cover

- The compaction-ownership TODO items (1-9). Each TODO has its own
  "Verify" subsection with concrete commands for that work item.

## Out of scope

- **`context.compact` non-compaction actions** (`context.check`,
  `context.get`, etc.). The BatchSizer sizes them like any other
  tool result; no separate handling. If users want a deeper view
  of "what just happened in my context," that's a UX decision for
  later.
- **Per-LLM-provider context-limit heuristics.** The Agent's
  `context_limit` is currently whatever the LLM config reports. If
  we need a tighter policy (e.g., hard-cap below the model's max
  output), that's a separate change.

## TODO: compaction ownership half of the redesign

Items 1-11 in "Implementation outline" are landed. The remainder is
the compaction-ownership work: the parts of the doc that deal with
what happens *if* compaction fires, not whether compaction fires.

The outline below covers:

- **Compactor fixes** (TODOs 1-3): the `Compactor.compact/3` API
  change, the `Compaction.spawn/5` single failure-path rewrite, and
  the new `:compaction_failed` Agent status.
- **Pending-user-message plumbing** (TODO 4): the
  `state.chat_state.pending_user_message` field that makes the
  user message append exactly once.
- **Channel + Agents API** (TODOs 5, 7): rejection in compacting
  state, retry channel, retry API.
- **Frontend** (TODOs 6, 8): retry button wiring + banner.
- **Test cleanup** (TODO 9): invert the tests that currently pin
  the silent-success bug.

Each TODO below lists:

- **What:** the change.
- **Why:** the prior-doc rationale + any new context.
- **Files:** primary file(s) to touch.
- **Tests:** test additions/changes.
- **Verify:** how to confirm it works.

---

### TODO 1: `Compactor.compact/3` returns `{:ok | :error, _}` (no placeholders)

**What.** Currently `Compactor.wrap_summary/2` synthesizes
`"[Summary of earlier conversation]"` and `"[Summary of recent work]"`
literal placeholders when the LLM returns empty or non-string text.
These leak into the user-visible summary and violate the UI
transparency principle (per `notes/extract-compaction-and-resumable-chat-turn.md`
"Problems" §4).

**Why.** Placeholders mask the fact that summarization failed; users
see a fake-looking summary rather than the empty response.

**Files.** `lib/nest/tokens/compactor.ex`.

**Tests.** `test/nest/tokens/compactor_test.exs`:

- Existing `wrap_summary/2` tests for placeholders are inverted to
  assert empty/raw LLM text is passed through unchanged.
- Add: `Compactor.compact/3` returns `{:error, :llm_returned_empty}`
  when the LLM call returns empty / non-string.
- Add: `:too_short` branch returns `{:ok, original_messages}`
  unchanged.
- **Note:** `:too_short` and successful-run branches both return
  `{:ok, messages}` — no special-case 3-tuple. Caller distinguishes
  via `length(messages) == length(input_messages)` if it needs to.

**Verify.** `mix precommit` clean; `mix test` passes;
`compactor_test.exs` covers the empty-input case.

---

### TODO 2: `Compaction.spawn/5` single failure path

**What.** Today, `Compaction.spawn/5`'s `send_failure/4` for the
`{:chat_continuation, _}` and `{:task_compaction_continuation, _}`
shapes falls through to a generic path that sends
`{:compaction_done, original_messages, continuation}` — treating the
failure as a success with no compaction applied. The chat task then
resumes based on the original messages, which is wrong (a state-
corruption bug, listed as "Problems" §2 in the doc).

The doc's design says compaction's failure path is uniform:
`{:compaction_failed, reason, continuation}`. The Agent's handler
routes by continuation shape, not by message type.

**Why.** Today a failed compaction silently looks like a success.
This masks LLM-call failures (Compactor has timeouts / network
errors) and corrupts subsequent iterations.

**Files.**

- `lib/nest/agents/agent/compaction.ex`: rewrite `send_failure/4` to
  send `{:compaction_failed, reason, continuation}` for all shapes.
- `lib/nest/agents/agent/handlers.ex`: route
  `{:compaction_failed, _, _}` to `CompactionHandler`.
- `lib/nest/agents/agent/handlers/compaction_handler.ex`: add a
  `handle({:compaction_failed, reason, continuation}, state)` clause
  that sets `:compaction_failed` Agent status (TODO 3) and routes
  the continuation appropriately.
- `lib/nest/agents.ex`: add `retry_compaction/1` (also TODO 7).
- `lib/nest_web/channels/agent_channel.ex`: add
  `chat:retry-compaction` handler (also TODO 5).

**Tests.**

- `test/nest/agents/agent_compaction_test.exs`: add
  `"compaction_failed transitions Agent status to :compaction_failed"`,
  `"chat:message is rejected while :compaction_failed"`,
  `"chat:retry-compaction re-runs the compactor"`.
- Add a regression for the silent-corruption bug — currently the
  chat task asserts `:task_compaction_done` was received even on
  failure, which is the bug; the test should be inverted to assert
  `:task_compaction_failed` (or the new contract).

**Verify.** `mix precommit` clean; `mix test` passes; integration
test: stub the compactor's LLM call to return empty; assert the
agent goes into `:compaction_failed`, the channel rejects
`chat:message`, and `chat:retry-compaction` re-runs the compactor.

---

### TODO 3: `:compaction_failed` Agent status + `chat:error` broadcast

**What.** When `Compaction.spawn/5` returns `{:error, reason}`, the
Agent:

1. Sets `status: :compaction_failed`, `cancelled: false`.
2. Broadcasts `chat:error` with the user-facing message.
3. Broadcasts `chat:status` so the UI reflects the new state.
4. Preserves `pending_user_message` (TODO 4).
5. Does NOT spawn a new chat task. Does NOT send any messages to
   any chat task. The old chat task already exited.

**Why.** The user can retry. Without an explicit Agent-side status,
the UI can't distinguish "compaction succeeded but a prior turn
ended" from "compaction failed; here's why."

**Files.**

- `lib/nest/agents/agent/chat_state.ex`: `:compaction_failed` is
  already in the status enum (verify).
- `lib/nest/agents/agent/handlers/compaction_handler.ex`: handler
  for `{:compaction_failed, _, _}` (from TODO 2).
- `lib/nest/agents.ex`: `retry_compaction/1` route (TODO 7).

**Tests.** `test/nest/agents/agent_compaction_test.exs` — verify
status transition + broadcasts.

**Verify.** With the compactor stubbed to fail: agent's status
becomes `:compaction_failed`; `chat:error` is broadcast with the
reason; `chat:status` reflects the new state; no chat task is
spawned.

---

### TODO 4: `state.chat_state.pending_user_message`

**What.** Per the prior-doc redesign: `handle_chat/3` stores the
user message in `state.chat_state.pending_user_message` (with
`index: nil`). It does NOT call `__append_message__/2`. We can't
assign an index until we know what compaction does to the message
list.

The pending message is appended:

- After compaction succeeds, in the Agent's `compaction_done/3`
  handler, just before spawning the new chat task.
- If compaction isn't needed, in `handle_chat/3` itself, before
  spawning the chat turn.

**Why.** Today, `handle_chat/3` appends the user message twice when
compaction fires (Problems §3). The `:compaction_failed` state also
needs to keep the pending message so a `chat:retry-compaction`
(from TODO 5) re-attaches it.

**Files.**

- `lib/nest/agents/agent/chat_state.ex`: add `pending_user_message`
  field to the struct.
- `lib/nest/agents/agent.ex`: initialize the field in
  `Init.build_state/2`.
- `lib/nest/agents/agent/chat_pipeline.ex`: `handle_chat/3` stores
  in `pending_user_message` (no `__append_message__/2`); the
  post-compaction handler appends + clears the field; resume path
  (no compaction) appends before spawning the chat turn.
- `lib/nest/agents/agent/handlers/compaction_handler.ex`:
  `compaction_done/3`'s `chat_continuation` branch appends the
  pending message + clears it.

**Tests.**

- `test/nest/agents/agent_compaction_chat_continuation_test.exs`
  (already exists) needs revision: today it tests the in-memory
  double-append bug. Pin the new contract: pending message is
  appended exactly once.
- `test/nest/agents/agent_compaction_test.exs`: add
  `"user message is appended exactly once when compaction fires"`.

**Verify.** `mix precommit` clean; the chat_continuation test
catches the regression.

---

### TODO 5: Channel rejects `chat:message` while compacting/`:compaction_failed`

**What.** `chat:message` is rejected when the agent's status is
`"compacting"` or `"compaction_failed"`. Reply:
`{:error, %{"reason" => "agent_status_compacting"}}` or
`"agent_status_compaction_failed"`.

`chat:retry-compaction` is the only action accepted in
`"compaction_failed"` state. It sends `:retry_compaction` to the
Agent pid.

**Why.** Without the rejection, a user-sent message during a failed
compaction would be persisted into the agent's `pending_user_message`
and trigger its own compaction path, doubling the work. The
retry-compaction path is the only sane action in
`"compaction_failed"` state — the user must retry the compactor
rather than send a new message.

**Files.** `lib/nest_web/channels/agent_channel.ex`:

- `handle_in("chat:message", ...)` — guard on agent status.
- **NEW** `handle_in("chat:retry-compaction", _payload, socket)` —
  forwards to Agent pid.

**Tests.** `test/nest_web/channels/agent_channel_chat_test.exs`:

- Existing rejection tests remain (they pass today once the agent's
  `status` is `"compacting"`).
- Add: `"chat:retry-compaction sends :retry_compaction to the Agent"`.
- Add: `"chat:message rejected with agent_status_compaction_failed"`.

**Verify.** `mix precommit` clean; integration test via
`AgentChannel.join` + `push("chat:message", ...)`.

---

### TODO 6: Wire frontend `chat:retry-compaction` event handler

**What.** When `"chat:retry-compaction"` is dispatched from the
channel, the JS frontend sends `chat:retry-compaction` to the
server. The retry banner's button calls
`channel.push("chat:retry-compaction", {})`.

**Why.** Companion to TODO 5.

**Files.** `assets/js/channels.js`: event handler for incoming
notifications (none — the button does the push).
`assets/js/components/StatusBanner.jsx` or wherever the retry
button lives: dispatch the push.

**Tests.** `assets/js/channels.test.js`: ensure the
`chat:retry-compaction` push is wired (already covered if the
test pattern is "given x, channel.push is called").

**Verify.** Manual: agent in `:compaction_failed` state, click
"Retry compaction," agent re-runs the compactor.

---

### TODO 7: `lib/nest/agents.ex` `retry_compaction/1`

**What.** Public API:
```elixir
@spec retry_compaction(String.t()) :: :ok | {:error, term()}
def retry_compaction(name)
```
Sends `:retry_compaction` to the agent's pid.

**Why.** Channel + frontend need a way to trigger a retry.

**Files.** `lib/nest/agents.ex`.

**Tests.** `test/nest/agents_test.exs`: assert that
`retry_compaction/1` calls the agent's `handle_info(:retry_compaction, ...)`
(checked via `:sys.get_state/1`).

**Verify.** After compaction fails, calling
`Agents.retry_compaction(name)` re-runs the compactor (asserted
via `:compaction_done` broadcast or `chat:status` flip).

---

### TODO 8: Frontend: hide chat input + show retry button

**What.** When `status` is `"compacting"` or `"compaction_failed"`,
the chat input is replaced with a banner. When `"compaction_failed"`,
the banner carries a `Retry compaction` button (disabled in
`"compacting"`). The button calls
`channel.push("chat:retry-compaction", {})`.

**Why.** Companion to TODO 5/6.

**Files.**

- `assets/js/components/ChatInput.jsx` (or wherever the input
  lives): hide + show banner.
- New component or extension of an existing one for the retry button.

**Tests.** `assets/js/components/ChatInput.test.jsx` (or equivalent):

- Banner shown when `status === "compacting"`.
- Retry button rendered + enabled when
  `status === "compaction_failed"`.
- Clicking the button calls `channel.push("chat:retry-compaction", ...)`.
- Input re-enabled when status returns to `"idle"` / `"streaming"`.

**Verify.** `mix precommit` clean (biome + tests); manual UI check.

---

### TODO 9: Update doc tests that locked the silent-success bug

**What.** Several existing tests assert that `chat_continuation`
failure produces a `{:compaction_done, original_messages, _}` message
(e.g., in `agent_compaction_chat_continuation_test.exs`). Under TODO 2,
that message is replaced with `{:compaction_failed, reason, _}`.

**Why.** Cleanup so the regression test pins the new contract.

**Files.** `test/nest/agents/agent_compaction_*_test.exs`.

**Tests.** Update assertions as part of TODO 2's test additions.

**Verify.** `mix test` clean.

---

## Suggested ordering for the remaining work

1. **TODO 1** (`Compactor.compact/3` API). Smallest, isolated.
2. **TODO 2 + TODO 3** (single failure path + `:compaction_failed`
   status). Combined because they share the same handler.
3. **TODO 9** (doc test updates). Concurrently with TODO 2.
4. **TODO 4** (`pending_user_message`). Touches
   `chat_pipeline.ex` + `compaction_handler.ex` + persistence.
5. **TODO 7** (`Agents.retry_compaction/1`). Trivial.
6. **TODO 5 + TODO 6** (channel handler + frontend push).
7. **TODO 8** (frontend banner + retry button).

The early items (1-4) are the "Agent is fully correct" half; 5-8
are the "user can recover from a failed compaction" half. Splitting
into two PRs is reasonable.

---

## Carried forward (still future)

- **Long assistant response trim.** Per the doc's prior "long
  assistant response" section: under the BatchSizer rewrite, an
  extremely long assistant message simply becomes a very-large
  assistant message in `state.chat_state.messages`. The next
  batch's `BatchSizer.preflight/2` refuses or the keep-or-summarize
  pass handles it. **No separate handling needed.** (If users
  complain about extreme cases, revisit.)

- **Per-LLM-provider context-limit heuristics.** If we ever need a
  tighter policy than "trust the LLM config's `context_limit`" (e.g.,
  hard-cap below the model's max output, or per-task cap that
  reserves room for tool-call iteration), that's a separate change.

- **`:compaction_failed` retry budget.** Currently, `chat:retry-compaction`
  re-runs the compactor with no attempt limit or back-off. If the
  underlying LLM call is structurally broken (wrong model id, bad
  API key, etc.), the user will hit the failure state repeatedly.
  A future change should detect "the same reason keeps recurring" and
  surface a different error class.
