# Issue #15 — deliver messages at the turn boundary

Branch `boundary-delivery` (off `main`). This is the design note for the
machine half of #15; #17 (`agents-wait` + async modes) lives on
`async-messages` and is independent.

> We shouldn't wait for idle to deliver agents-send messages. Certainly we
> should let the outstanding API request or tool execution finish, but we
> should deliver messages before starting a new thing.

## Today

The inbox is drained **only** when the target goes idle:

- `Transitions`/`Response`/`Compaction` emit `{:drain_inbox}` on every
  terminal path (`{:finalize, :clean}`, `fail_turn`, `llm_error`, the
  `:stopping` → idle path, `{:unblocked}`, `:workspace_notice`, and the
  compaction resumes).
- `Inbox.handle_delivery/3` drains immediately when the target is
  already `:idle`.

So a message that arrives while a turn is running — a peer's
`agents-send`, or a human chat message — waits for the **whole** turn,
even when the turn is between two LLM requests and is about to start
another one. A long agentic turn can be dozens of requests long.

## The boundary

There is exactly one safe point inside a chat turn where the wire
sequence is complete and no work is in flight:

**`Transitions.iterate/1`, in phase `:generating`/kind `:chat`.** That is
where the machine is about to start a new LLM request, reached from
`tool_results/2` (tools finished), `start_chat` (turn opening), the
truncation/silent re-prompt, and `recover_interrupted_tool/1`.

At that point:

- any in-flight HTTP request has already landed (the response was
  applied and appended), and
- any in-flight tool batch has already landed (the results are appended),
  so no `Part.ToolUse` is unanswered.

That is precisely "let the outstanding API request or tool execution
finish, then deliver before starting a new thing".

### The rule

At `iterate/1`, **inside the existing `[] ->` branch of the
`unpaired_tail_tool_uses/1` case**, deliver instead of dispatching when
all of these hold:

1. `ctx.inbox_count` is a positive integer, and
2. `work.force_finalize` is false, and
3. the transcript tail is a `{:tool, _}` or `{:assistant, _}` message.

Then emit `[{:drain_inbox}]` and stay in `:generating`. The executor
drains the inbox and hands back the existing `{:inbox_drain, entries,
content}` follow event, which the machine now also accepts in
`:generating`/`:chat`: it builds the user message exactly as the `:idle`
clause does and calls `start_chat/3`.

Condition 1 is `is_integer/1`-guarded: `nil > 0` is true in Erlang term
order, and ~25 test files build `ctx` by hand.

Condition 2 keeps `force_finalize`'s meaning ("wrap this turn up now"):
at the `:overflow_tool_calls` and `refuse_mixed` boundaries the machine
has just appended synthetic tool results and asked the model for a final
answer, so the forced finalize completes and the queued message is
delivered at the turn end, exactly as today.

Condition 3 excludes the one shape where delivering would append a user
message onto a message the machine itself just appended (a turn opening,
including `Compaction.resume/1`'s `resume_with_pending/1` path, which
re-enters `:generating` from `:idle` and calls `:iterate`).
`MessageList.last_wire_role/1` is *not* usable for this guard: it maps
`{:tool, _}` to `:user` (a tool message is a user-role message on the
wire), and the tool tail is exactly the case we want to allow. Match the
message tag instead.

The `{:assistant, _}` half of condition 3 is defensive rather than a live
boundary: every path that reaches `:iterate` with an assistant tail either
carries an unanswered `Part.ToolUse` (preflighted) or goes to `:idle`
first. It is admitted anyway because an assistant tail is legal for an
append, and because without the drain the only other outcome for that
shape is `dispatch_http/1` → `Preflight.validate_request/1` →
`:no_trailing_assistant` → a failed turn.

The `unpaired_tail_tool_uses/1` position is load-bearing, not
stylistic. A `{:assistant, _}` tail *can* still carry unanswered
`Part.ToolUse`: `Compaction.resume/1` re-enters `:generating` with a
carried `{:tool_call, assistant, ...}` entry and no ack
(`machine/compaction.ex:126-143`, `turn/commit.ex:79,107-115`), and
`compaction_failed/3` does the same. Those are reachable mid-turn (a
preflight `{:refuse, _}` stages a compaction), and compactions are long,
so an inbox entry arriving during one is likely. Draining there would
append a user message onto an unanswered `tool_use` → `Repair` returns
`{:invalid, _}` → the turn fails. Requiring the unpaired list to be
empty closes that hole; the tail-tag check then only has to exclude the
just-opened-turn shape.

### Known, accepted residual exposure

The drained entries are cleared by the executor's `{:drain_inbox}`
before the follow event, so an append that is refused as `:invalid`
loses them (the same is true of the existing `:idle` drain, and the
failure path carries only the repair reason). With conditions 1–3 this
is not reachable: a user message onto a `{:tool, _}` tail is bridged,
onto an `{:assistant, _}` tail it is legal, and the size case is decided
by `start_chat/3`'s preflight before the append. Making it lossless by
construction would need a second drain shape (peek + consume) or a
pending-entries slot on the machine, i.e. new state for a case that
cannot be constructed — rejected in favour of one drain path and a
comment. If it ever does happen, the honest fix is a restore action
before `fail_turn/3`, not a silent drop.

### Also fixed here: a held message and the compaction loop breaker

`start_chat/3`'s `:needs_compaction` branch parks the drained message on
`pending_user_message`. That is lossless on every normal path, but the
compaction loop breaker used to clear it while the executor had already
consumed `state.live.inbox`, so the message existed nowhere afterwards
(reachable after three `:retry_compaction`s leave `loop_count` above the
breaker's threshold). `:loop_ack` now appends the held message before its
`{:drain_inbox}`, so the operator's acknowledgement keeps it in the
transcript instead of dropping it; a refused append surfaces as a turn
failure rather than a silent loss. No turn is dispatched by that append —
that would re-enter the compaction decision which just gave up — so the
message is answered by the next turn. The same drop predates this work on
the human-chat path, which is why it is fixed here rather than only
documented.

### Known limits found in review (tracked, not fixed here)

* **A parked message is invisible on the wire while it waits.** When a
  drained message does not fit, `start_chat/3` parks the built message on
  `pending_user_message` and the executor has already cleared and
  rebroadcast the inbox (`chat:inbox` count 0), so between the drain and
  the compaction's resume the human's message is in no payload — not in
  the inbox list, not in the transcript, not in `pendingMessageCount` —
  even though the agent is visibly `:compacting`. Making it visible needs
  either the parked entry in the inbox payload or a peek-then-consume
  drain (new state, or a second drain shape), which is more than this
  change should carry.
* **The human queue bypasses `@max_inbox_size` and is unbounded.** The cap
  bounds a runaway *agent* producer; a human message is queued even at the
  cap so a click cannot silently vanish. The queue is in-memory and grows
  for the whole turn, and `Broadcasts.inbox/2` re-sends the whole
  serialized list on every enqueue, so `n` queued frames cost `~n²·s/2`
  bytes of PubSub traffic. Human typing self-limits this in practice, and
  the app has no rate limiting on any channel event today (an idle agent
  can be spammed into unbounded DB growth just as easily), but it deserves
  a bound of its own.

### Why this shape (and not "end the turn, then start a new one")

The obvious alternative — finalize the turn and let the existing
`:idle` drain start a fresh turn — was rejected:

1. **It manufactures a transient idle.** `Turn.settle/2` broadcasts the
   status after each settle step, so the sequence would be
   `streaming → idle → streaming`. `agents-query`'s blocking wait is
   idle-based (`ToolLoop.wait_for_idle/5` reads the target's newest
   assistant message once it sees `chat:status: idle`), so it would
   resolve with whatever the target had said *before* the delivery —
   a silent wrong answer. Not fixable without a second signal.
2. **It fires `:child_completed` at the parent.** Every `{:finalize,
   :clean}` calls `send_parent/2`, so a pre-empted sub-agent would
   report a partial result to a parent blocked in `agents-spawn` /
   `agents-query`, and `Children` makes the first completion
   authoritative.
3. **It would need a new terminal/action and a new "is this a real turn
   end?" concept.** Staying in `:generating` needs neither: the phase
   (and therefore the observable status) never changes, and
   `start_chat/3` already owns the fits / needs-compaction /
   cannot-compact decisions, including the `{:restore_inbox, entries}`
   path that makes the drain lossless.

The delivered message still gets a **fresh turn budget**: `start_chat/3`
runs `init_turn/2`, which resets `iteration`/`max_iterations`/
`force_finalize`. That matches today's semantics, where each drained
message starts its own turn.

## What the model sees

`[..., assistant(tool_use), tool(result), assistant(ack), user(msg), ...]`

The `assistant(ack)` is not new machinery: `Repair.classify_live/2`
permits exactly one shape on the live path — a user message onto a
wire-`user` tail — and bridges it with
`MessageList.idle_bridge_ack(:live)` ("Okay, continuing from here.").
A `{:tool, _}` message *is* a wire-`user` message, so the bridge fires
for the common case (delivery after a tool batch) and does not fire when
the tail is already an assistant.

Two comments become stale and must be corrected (the shape is now
reachable by design, not a last-resort guard):

- `Repair`'s moduledoc and `classify_live/2` doc ("should be unreachable
  in production").
- `MessageAppender`'s moduledoc ("a user message is rejected mid-turn").

## Losslessness

- The inbox is cleared by the executor **only** when it hands the
  entries back in the follow event; `start_chat/3`'s `:cannot_compact`
  branch restores them with `{:restore_inbox, entries}` (unchanged).
- If the append itself is rejected (`:invalid`), `fail_turn/3` ends the
  turn cleanly; the content is in the message the appender refused, so
  it is surfaced as a turn failure rather than silently dropped. No new
  path is introduced here: the same is already true of the `:idle`
  drain.
- A message arriving *during* a settle step cannot interleave: the whole
  drain → append → dispatch chain runs inside one `settle/2` recursion
  in the Agent process, so `Inbox.handle_delivery/3` sees either the
  pre-turn status (queues) or a status that will reach the next
  boundary.

## Human messages during a turn (#15, second half)

Today a human message sent mid-turn is rejected outright: the channel
answers `{:error, %{"reason" => "agent_busy"}}` for `:streaming` /
`:executing_tools` (`AgentChannel.handle_in("chat:message", ...)`), and
`Callbacks.chat_or_drop/3` drops the cast as defense-in-depth.

The atomic place to change this is **`Callbacks.chat_or_drop/3`**, not
the channel: it runs in the agent process and therefore sees the true
status, so check-and-enqueue cannot race. The channel's status check
stays only as UX (a nicer error for the broken statuses) and must no
longer reject the working ones.

- `chat_or_drop/3`: `:idle` → `ChatPipeline.handle_chat/3` (unchanged);
  `:streaming` / `:executing_tools` / `:compacting` → enqueue on the
  agent's own inbox and broadcast (no drop); broken statuses → unchanged
  error.
- The queued entry records that it came from the human
  (`kind: :user`, so the combined drain text reads
  `[Message from the user "<id>"]` instead of `[Message from agent
  "..."]`) and **carries the requested mode**.
- **The mode is applied at drain time, never at enqueue time.** Setting
  `state.live.mode` when the message is queued would re-resolve
  `ctx.mode`/`ctx.caps` for the *ongoing* turn's remaining tool calls
  (`Turn.build_ctx/2` runs on every settle) — a mid-turn capability
  change nobody asked for. The executor's drain sets
  `state.live.mode` from the entry before it emits the follow event, so
  the ctx prepared for the delivery step (and the new turn it starts)
  carries the human's mode, prefix and caps. One mode per combined
  message; when entries disagree, the most recent user-sourced entry
  wins, and that rule is documented in `Inbox`.
- The composer *was* disabled while the agent is busy (`ChatInput.jsx`)
  and `isAgentBusy` gated the send (`ChatPage.jsx`), so the queued path
  had to be made reachable at all: while busy the textarea and mode
  selector stay enabled and Send is rendered next to Stop. The
  slash-command menu stays suppressed there, and a slash command typed
  while busy is queued as ordinary chat text rather than dispatched (a
  control-plane push cannot take effect mid-turn).
- A queued message must not leave the optimistic bubble behind.
  `sendMessage` inserts the user's row before the push at a *fabricated*
  index, plus a fabricated assistant `streaming`/`partial` placeholder
  after it (`channels/agent.js`, `store/slices/agentCacheMessages.js`) —
  that is the optimistic echo for the normal case, where the server
  appends the real row at the same index moments later. When the message
  is only queued, no real row arrives until the drain (a long turn
  later), so the fabricated index is eventually occupied by an unrelated
  real row: `addChatMessage` matches by index first, `buildMerged`
  overwrites the user's text, the content fallback misses for a long
  turn → duplicate bubble, duplicate React key, and `syncAgentMessages/2`
  then skips the real row forever.
  The fix keys off the authoritative signal instead of a status guess:
  the agent broadcasts `chat:inbox` when it queues the message (with
  `kind: "user"`, the verbatim content, the mode and the sender), and
  `setAgentInbox` retracts the oldest still-present optimistic row whose
  content matches a user-sourced entry — re-anchoring `lastIndex` on the
  newest surviving real row and clearing the fabricated placeholder only
  when it belongs to that send. The optimistic row is tagged
  `optimistic: true` so a real row can never be retracted. The queued
  message is then visible in the inbox panel (which already renders the
  list) until the drain delivers it as a normal `chat:message`.
  `kind`/`mode` are additive on the `chat:inbox` payload; the panel
  labels an `agents-send` entry by its sender, a human entry "From you"
  only when the sender is the current user, and shows the requested mode
  with an explicit missing marker.

## Boundaries deliberately not taken

- **After an HTTP response with tool calls** (before the batch runs): the
  `tool_use` is unanswered, so nothing may be appended.
- **The truncation / silent re-prompt boundary** (`Response`, the
  `{:reprompt, nudge}` branch): the tail is the nudge, a user message, so
  condition 3 excludes it. It is a genuine "nothing in flight" point and
  a missed optimisation; it is rare, and delivering there would append a
  user message onto a synthetic user message for no benefit.
- **The compaction *request* turn's `:iterate`**: it does not call
  `iterate/1` at all, and a user message cannot be injected into a
  compaction request. The **resume** after a `context-compact` commit
  *is* a taken boundary, though: `Compaction.resume/1` re-enters
  `:generating`/`:chat` and emits `:iterate` with the synthetic
  `tool_result` as the tail (`Response.compact_only/5` appends neither
  carried message; `Turn.Commit` puts the pair at the head of the new
  segment), so a message queued during such a compaction is drained
  there, before the post-compaction request. That is safe — the wire
  stays legal, the delivered message gets a fresh budget, and delivering
  before the next request is the whole point — but it *is* a behaviour
  change, not "unchanged". On the `resume_with_pending/1` path the
  resume appends the *held* user message first, so the tail is a
  `{:user, _}` and the drain waits for the next boundary.
- **`{:preflight_result, :fits}`**: the batch is about to run and must
  answer the `tool_use`.

## Other decisions

- **`work.preflight` is deliberately not cleared by `Phase.enter/4`.**
  `Response.regular/5` sets `preflight` *before* calling
  `Phase.enter/4`, so clearing it there would break the normal tool-call
  path. A stale batch is harmless: it is only ever read by the
  `{:preflight_result, _}` clauses, which are only reached after a
  `{:preflight, ...}` action, and both emitters set the field first.
- **The `{:drain_inbox}` action may return no follow event** when the
  inbox is empty (`Turn.Executor`), which would leave the machine in
  `:generating` with no worker and no pending event. It cannot happen
  here: `prepare/1` rebuilds `ctx` from `state.live.inbox` immediately
  before every step, and the decision and the action run inside one
  settle step with no awaits in between, so `ctx.inbox_count > 0`
  implies a non-empty inbox at the drain. A machine test pins the
  emitted action and an integration test pins the delivery, so a future
  refactor that breaks the coupling fails loudly instead of wedging.
- **The status can leave `:streaming`** on the delivery path when the
  new turn does not fit and `Compaction.stage/3` runs: the agent goes
  `:compacting` (and, with task D, `chat_or_drop/3` would queue rather
  than start). That is correct, just not the "never leaves `:streaming`"
  claim the first draft made.
- **Idle-based waits are unaffected but can be starved.** `agents-query`
  (`ToolLoop.wait_for_idle/5`) and `agents-wait` (`Agent.WaitLoop`) both
  wait for a peer to go idle, and a peer that keeps receiving messages
  keeps starting new turns. Neither is resolved *falsely* by this design
  (no transient idle is broadcast), but both can now wait longer.
  Worth a test on the delivery side; not a behaviour change to the waits.
- **The inbox signal is `ctx.inbox_count`, read through one documented
  accessor that defaults to 0.** `build_ctx/2` always sets it (from
  `length(state.live.inbox)`), so the default only ever applies to the
  ~34 test files that build a `ctx` map by hand, where "no queued
  messages" is the intended state. A strict read would force a
  mechanical fixture edit across all of them for no signal. It lives on
  `ctx` rather than on the machine (or `Machine.Work`) for a freshness
  reason, not a cap reason: `Turn.build_ctx/2` is its single producer and
  `Turn.prepare/1` rebuilds `ctx` immediately before every step, so the
  value can never be stale. (The structs are not at their caps — credo
  allows 16 fields, `Machine` has 10 and `Machine.Work` 12 — so this is
  not forced by the field cap; the accessor's 0 default is what keeps the
  hand-built fixtures honest, and the integration test pins that a
  production `ctx` always carries the key.)
- **Stale comments to correct** (beyond the two named above):
  `repair.ex:24-28,97-100,113-115`,
  `message_appender.ex:38-41`, `message_list.ex:192-201,309-350`,
  `inbox.ex:12-15`, `chat_state.ex:133-137`, and the LLM-facing
  `agents-send` description in `tools.ex:437-449` ("once it finishes its
  current turn" is no longer the whole truth).

## Tasks

| task | scope | risk |
| --- | --- | --- |
| **C** | boundary check in `iterate/1`, `{:inbox_drain, ...}` in `:generating`/`:chat`, `ctx.inbox_count`, comment corrections, tests | high |
| **D** | channel queues instead of rejecting; `kind`/mode on the inbox entry; JS queued-state handling; tests | medium |

## Acceptance

- `ctx` carries the inbox size (`build_ctx/2`); the machine stays pure.
- A message queued during a tool batch is appended as a user message
  **before** the next HTTP request, and the delivery itself changes no
  status: it does not pass through `:idle`. (The status can still move
  for reasons that are not the delivery — the
  `:executing_tools → :generating` transition that precedes it, or
  `:compacting` when the delivered message does not fit and a compaction
  is staged; see "Other decisions".)
- No message is lost, and the drained order is preserved.
- `mix precommit` clean; the Elixir suite stays under 5s.
- Tests: machine-level (tail guard, fits, needs-compaction,
  cannot-compact/restore) plus an integration test that a queued
  `agents-send` lands mid-turn without the agent ever going idle, and
  that the delivered user message is bridged when the tail is a tool
  message.
