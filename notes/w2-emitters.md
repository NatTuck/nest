# W2 emitters — site → event → payload

Where each `Nest.Timeline.record/4` call belongs, what it fills, and what is not
available where it would naturally fire. The payload keys are exactly the schema
in `Nest.Timeline`'s moduledoc (`notes/observation-kit.md` repeats it for the
reader), so an emitter that follows this table needs no judgement call.

Two rules apply to every site below:

* **`agent` is the owning agent.** For a child event that means the *parent*:
  the executor runs in the parent's process, so a batch child's `spawned` event
  is recorded against the parent with the child in `name` — that is what makes
  the child graph read as the parent's view. The batch coordinator is a task,
  not an agent, and emits nothing of its own.
* **Never content.** Arguments and results go through `redact/2` (head + size) or
  `bytes/1` (size only). No transcript, no whole tool result, no whole message.

## `turn` — the transition funnel

**Site:** `Nest.Agents.Agent.Turn.settle/3` (`lib/nest/agents/agent/turn.ex`),
**anchor:** immediately after `Machine.step/2` returns, where the old `machine`
and the returned `next` are both in hand. Emit for the `{:ok, …}` and
`{:ignore, …}` arms alike (an ignored event is a transition the reader wants to
see); not for `:quarantine` — that is the `error` type's job.

**Payload:** `event` = the event tag (see below), `from` / `to` = `{kind, phase}`
of `machine` and `next`, `iteration` / `max_iterations` from `next.work`,
`message_indices` = see below.

**Subtle:**

* The tag is not on the event directly — `{:http_ok, ref, response}` is a tuple.
  `Machine`'s `event_tag/1` is the one mapping; it is private today, so either
  make it public or derive `elem(event, 0)` for tuples and the atom itself for a
  bare atom (`:iterate`).
* **`message_indices` must be threaded.** The indices are stamped by
  `MessageAppender` inside the executor, one settle later than the transition
  that decided them. The cheap honest form: capture `Enum.map(state.chat_state.messages, …index)` before the step and diff it against the same list after
  `run/5` returns — that means passing the pre-set into `run/5` (it already
  receives `old_status`; a second carried value is the whole change). Deriving it
  any later is impossible: the next settle's `prepare/1` has already replaced the
  machine.

## `llm` — the sizing point

**Site:** `Nest.Agents.Agent.Machine.Transitions.do_dispatch_http/1`
(`lib/nest/agents/agent/machine/transitions.ex`), **anchor:** right before the
`{:spawn_http, spawn_ctx}` action is returned, where `m.work.iteration`,
`m.work.max_iterations` and `ctx.messages` are all in hand. (The pure module
cannot record, so the emitter belongs to the action's *executor*
(`Turn.Executor`'s `{:spawn_http, …}` clause) — same values, effect-side.)

**Payload:** `message_index` = `ctx.next_message_index`, `iteration`,
`model` = `ctx.client_config.model`, `projected_tokens` =
`ConversationSize.size(Dispatch.request_messages(m))` (the number the request
actually costs — it is not computed anywhere today, so the emitter computes it),
`limit` = `ctx.context_limit`, `reserve` = `Reserve.compaction_reserve(limit)`,
`remaining` = `Budget.remaining(messages, limit)`, `outcome` = `"sent"`.

**Subtle:** the *outcome* of the request is a different settle: `{:http_ok, …}`
is classified in `Machine.Response.dispatch/2` (which has the `RunResponse`), and
`{:http_error, …}` / `{:llm_error, …}` / `{:worker_crashed, …}` are their own
transitions. Those already show up as `turn` events with the response tag. If the
`llm` line itself must carry the result, the response site has to be a second
`llm` event (`outcome` = stop reason / `"error"`), and the *estimates* are then
not repeated on it — the pair of lines is the record.

## `tool` — the result path

**Site:** the driver, `Nest.Agents.Agent.Timeline.tools/3` called from
`Turn.settle/2`'s `{:ok, …}` arm (`lib/nest/agents/agent/turn.ex`), **anchor:**
where the step accepted the `{:tool_results, ref, results}` event. One event per
result (a batch of three calls is three lines). The *values* are the ones the
transition has (`Transitions.tool_results/2` builds the tool message from the
same structs), but the recording is an effect and the transition table is pure —
the same correction this table already makes for `llm`.

**Payload:** `name` / `tool_call_id` / `is_error` from the `%ToolResult{}`,
`args_head` + `args_bytes` = `Timeline.redact("args", result.arguments)`,
`result_bytes` = `Timeline.bytes(result.content)`, `worker` =
`m.work.active_worker_kind`, `duration_ms` = see below.

**Subtle:** **`duration_ms` is not available at this site — nothing measures a
per-call duration anywhere.** The tool worker does not measure one and the
machine has no start stamp, so there is no value to record and the field is
absent from every line (the digest prints no `ms` segment for it). The obvious
fix does not work: one duration on the `{:tool_results, ref, results}` message
would be the *batch's* lifetime, so a three-call batch would print three
identical numbers — the value has to be per result. That means a new field on
`%ToolResult{}`, which is serialized into the model's context, so the change
forces an explicit decision that the duration must never reach the model (an
exclusion in the message builder, or a parallel field it drops). Do not fake it
from `active_worker_kind`'s lifetime — the worker is spawned per batch, not per
call. Free alternative with no production change at all: every line already
carries `mono`, so the digest can show a batch's span from the `mono` delta
across its run of `tool` lines.

## `inbox` — enqueue / deliver / refuse

Four sites, one per action:

* **`delivered` / `queued` / `refused`** — `Nest.Agents.Agent.Inbox.handle_delivery/4`,
  **anchor:** at each `{:reply, …}` (the three arms already have `status`,
  `kind`, `sender` and the disposition in hand). Payload: `action` from the arm,
  `from` = the sender, `kind`, `mode` (`nil` on this path), `bytes` =
  `Timeline.bytes(content)`, `count` = `length(state.live.inbox)` after the
  enqueue (`nil` for a refusal), `disposition` = the atom returned to the sender
  (`:delivered`, `:queued`, `:inbox_full`, `{:status, …}`).
* **`enqueued`** — `Inbox.enqueue_user_message/4` and `Inbox.enqueue_internal/4`
  (the human path and the runtime's own result), **anchor:** just before the
  broadcast. Same fields; `disposition` = `:queued` (both bypass the cap and
  never refuse).
* **`drained`** — the executor's consume half, `Turn.Executor.consume_inbox/2`
  (`lib/nest/agents/agent/turn/executor.ex`), **anchor:** where the entries are
  dropped from the queue. That is the one point *every* drain passes (the idle
  path through `Turn.drain_inbox/1` and the machine-driven boundary drains
  alike) and the only one that knows the batch was actually delivered: a peek
  that parks (a compaction, a `:cannot_compact` block) leaves the entries queued
  and records nothing. Payload: `action: "drained"`, `count` = the batch size,
  `from`/`kind` = the batch's first entry (a batch may mix), `bytes` = the
  delivered entries' own content size (the combined string's separators and
  sender labels are the renderer's, not the messages'), `mode`/`disposition` =
  the mode the drain resolved.

**Subtle:** the *refusal* is the W1 invariant's whole point, so `disposition`
must be the value the sender was given, not a re-derivation. `handle_delivery/4`
builds it in each arm — record it there, not after the call returns.

## `debt` — set / cleared / reminded / gave up / give-up refused

* **`set`** — `Nest.Agents.Agent.Machine.Transitions.start_chat/3`,
  **anchor:** at `Machine.owe_replies/2` in the `:fits` branch (the senders are
  in hand there: `Inbox.query_senders(inbox_entries)`). This is the *delivery*
  point — a query that is still queued owes nothing (decision 3). Payload:
  `action: "set"`, `peer` = one event per sender, `reminders_used: 0`,
  `how: "delivered"`.
* **`cleared`** — `Turn.Executor`'s `{:reply_sent, sender}` clause (via the
  funnel's `{:reply_sent, …}` transition, `Machine.discharge_reply/2`), one event
  per cleared sender. `how: "reply_sent"`.
* **`reminded`** — `Nest.Agents.Agent.Machine.ReplyReminder.decision/2`,
  **anchor:** the `{:remind, text, machine}` branch, where `senders` (the due
  ones) are in hand. One event per sender; `reminders_used` = that sender's count
  *after* `Machine.count_reminders/2`; `how: "gate"`.
* **`gave_up`** — `Turn.Executor`'s `{:give_up_replies, reason}` clause,
  **anchor:** where `Machine.owed_senders/1` is read to deliver the notices. One
  event per requester; `peer` = the sender, `reminders_used` = that sender's
  count, `how` = the site's reason atom (`:stopped`, `:no_reminder`, …) — the
  same atom the funnel was given, which is the only place the *reason* survives.
* **`give_up_refused`** — `Nest.Agents.Agent.Turn.GiveUpDelivery.log_failure/5`,
  **anchor:** alongside the existing `Logger.warning`. `peer` = the requester
  that could not be reached, `how` = `GiveUp.failure_reason(why)`.

## `status` — the broadcast

**Site:** `Nest.Agents.Agent.Broadcasts.status/1`, **anchor:** immediately before
`Phoenix.PubSub.broadcast`, with the payload it is about to send.

**Payload:** `payload` = that map **verbatim**. It is the *broadcast* payload the
channel forwards, not the channel's own init payload (which carries `partial` and
would push the line toward the 8 KB stub).

## `notification` / `error` — `Broadcasts`

* **`notification`** — `Broadcasts.notification/3`, **anchor:** next to the
  broadcast. `notification_type` = the payload's `"type"`, `message` = its
  `"message"` (both already short by construction).
* **`error`** — `Broadcasts.error/6`, **anchor:** next to the broadcast.
  `message` = the message argument, `source` = the `[Source: Module.fn/arity]`
  tag the callers already pass (`"Turn.run/2"`, …) — it is a parameter, not
  something to derive.

## `compaction` — trigger and commit

* **`trigger`** — `Turn.Executor`'s `{:stage_compaction, ctx}` clause (the action
  `Compaction.stage/3` returns; the pure module cannot record). Payload:
  `trigger` = see below, `limit` = `ctx.context_limit`, `reserve` =
  `Reserve.compaction_reserve(limit)`, `used` = `ConversationSize.size(ctx.messages)`,
  `projected` = `Reserve`'s reserve arithmetic for the staged request (the value
  `Dispatch.compaction_plan/1` used), `carried` = the continuation's tag
  (`"assistant_response"` / `"tool_call"` / `"compact_tool"` / `"user_message"` /
  `nil`), `loop_count` = `m.loop_count`, `archived_to_index: nil`.
* **`commit`** — `Turn.Executor.commit_compaction/2`, **anchor:** after the
  marker is built, where `data` (summary text, staged, carried entry) and the
  rebuilt message list are in hand. Payload: `trigger` = `"commit"`,
  `archived_to_index` = the marker index, `carried` as above, `limit` /
  `reserve` / `used` / `projected` from the same values, `loop_count`.

**Subtle:** **`trigger` is not available at either executor site.** The *reason*
a compaction was staged (`:needs_compaction`, `:reserve_exhausted`, a manual
`/compact`, the `context-compact` tool, the loop breaker) is decided by the
callers of `Compaction.stage/3` (`Transitions` / `Response`), not inside it, and
only the staged *messages* ride the action. To fill it honestly, carry the reason
the way a caller-supplied focus already is: a fourth element on the staged entry
tuple (`{:compaction, staged, carried, trigger}`) or a `work.trigger` field read
next to `work.focus` in `Dispatch.compaction_plan/1`. Note that neither
`stage_request` builds a map: `Dispatch.stage_request/2` returns a message list
and `Compaction.stage_request/3` returns a machine — so "one more key" is not the
change. Until then, leave it out rather than guessing from the entry.

## `usage` — per-turn accumulation

**Site:** `Turn.Executor`'s `{:merge_metrics, usage}` clause, **anchor:** where
`Broadcasts.merge_usage_totals/2` folds the response's usage into the running
totals. (The child-usage merge, `{:merge_usage, name, usage}`, is a `child`
concern and belongs there, not here.)

**Payload:** `input` = `usage.input_tokens`, `output` = `usage.output_tokens`,
`cache_read` = `usage.cache_read_input_tokens`, `cache_write` =
`usage.cache_creation_input_tokens`, `total` = `usage.total_tokens` — the schema's
names are the short ones, the maps' are the long ones, and this is the only place
that translation happens.

## `child` — spawn and terminal

* **`spawned`** — `Nest.Agents.Agent.SubAgent.handle_spawn_request/3`,
  **anchor:** where `track_child/3` has registered the child (so the machine's
  entry exists) and the name is known. Payload: `action: "spawned"`, `name`,
  `vocation` = the opts' `:vocation`, `depth` = `state.depth + 1`, `model` = the
  resolved model, `clone_context` = the opts' flag, `archive` = the opts' flag.
  These four come from the spawn site *only* — the terminal events cannot fill
  them.
* **`completed` / `failed` / `terminated`** — `Turn.Executor`'s
  `{:child_message, name, result}` clause, **anchor:** before the delivery
  decision (target vs inbox). `action` from `result` (`{:ok, _}` → completed,
  `{:failed, _}` → failed, `{:terminated, _}` → terminated), `name`; the other
  payload keys stay empty — the executor does not have them, and inventing them
  from the child's registry entry would be a second source of truth.
* **`archived` / `stopped`** — the executor's `{:archive_child, name}` and
  `{:stop_child, name}` clauses, `action` + `name` only.
* **`usage` for a child** — the executor's `{:merge_usage, name, usage}` clause
  is where a child's cost is folded into the parent's descendant totals; if the
  child graph should carry cost, this is the site (with the same key translation
  as the `usage` type).

## Types with no honest site today

* `tool`'s `duration_ms` — nothing measures a per-call duration, and the machine
  has no start stamp (see above).
* `llm`'s `outcome` on the same line as the estimates — the response is a later
  settle (see above).
* `compaction`'s `trigger` — decided in a pure module, not carried on the action
  (see above).

Each is left out rather than approximated; each has a named change that would
make it available.

## What §3 landed, and the four places this table moved

The emitters live in `Nest.Agents.Agent.Timeline` (`lib/nest/agents/agent/timeline.ex`),
which owns every payload builder and calls `Nest.Timeline.record/4`. Each
public function checks `Nest.Timeline.enabled?/0` *before* building anything
(some payloads are not cheap — `ConversationSize.size/1` walks the message list)
and runs the builder inside a `rescue`, so an emitter cannot break a turn. The
sites are pinned by `test/nest/agents/agent/timeline_emitters_test.exs`, which
drives the runtime's own paths and renders a digest of the run.

Four things differ from the table above; each is a site or a field the doc could
not have known before the code was written:

1. **`turn` is emitted by the driver.** `Turn.settle/2`'s `run/6` records it
   after `Executor.run_all/2` has run (the `message_indices` diff needs the
   executor's stamps) and *before* the status broadcast it caused, so a
   subscriber woken by a status frame never finds the transition missing.
2. **`debt`'s `set` / `cleared` / `reminded` are a diff of the two machines.**
   The obligation is pure machine state and every writer of it is a transition,
   so the driver records the difference between the machine before the step and
   the machine after it (`Timeline.debt_changes/3`): a sender only in the new
   map was owed at delivery, one only in the old was discharged by the reply-sent
   transition (`discharge_reply/2` is the only in-step clear), and one whose
   count grew was reminded by the gate. That cannot drift from the writers the
   way a hand-placed emitter at each one would. `gave_up` is still the
   executor's, recorded *before* the notices are attempted (the decision is the
   event; a notice that fails is the `give_up_refused` line next to it), and
   `give_up_refused` is `Turn.GiveUpDelivery.log_failure/5`.
3. **`compaction`'s `used` / `projected` differ between the two lines.** On the
   trigger they are the compaction request's size and that size plus the reserve
   the request is allowed to spend (`Budget.fits?/2`'s arithmetic). On the commit
   they are the segment the commit archived and the rebuilt active segment, so
   the pair reads as the compaction's before → after. `trigger` is absent on the
   trigger line (see above), so a reader tells the two apart by that plus
   `archived_to_index`.
4. **Two renderings the schema does not spell out.** An `inbox` refusal's
   `disposition` is the value the sender was given, and the `{:status, _}` one is
   a tuple — a tuple cannot be encoded and the writer's answer to that is a stub
   that drops the whole payload, so the tuple is rendered as its `inspect` form.
   A child's `usage` line carries an extra `name` (the schema has no name field
   for `usage`), which the digest shows as an ordinary extra key.

And one site the table did not list: **`error` is also emitted by
`Turn.quarantine!/2`**, because a quarantined event has no transition and so no
`turn` line — the quarantine would otherwise be invisible in the timeline. The
event's `source` is `"Turn.quarantine!/2"`.
