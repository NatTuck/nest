# Issue #30 — the idle-based `agents-query` wait cannot tell the peer's own turn from the query's turn

Design note. No code in this note; the implementation follows review.

Found while implementing #15 (`notes/issue-15-boundary-delivery.md`, "Known
limits found in review"). The bug predates #15, but #15 changes how often it is
hit: before #15, a query to a busy peer was **dropped** by `Callbacks`'s
busy-branch (then `chat_or_drop/3`, busy → drop), so the wait resolved on the
peer's unrelated turn output — a wrong answer that looked like a success. #15
turned that branch into `chat_or_queue/4` (`callbacks.ex:75`), so the query is
now **queued** and delivered at the peer's next turn boundary, but the wait can
still resolve on the peer's own turn while the query's own turn starts later.

## Where the fix lands

The wait is `Nest.Agents.Agent.PeerQuery` on `async-messages` (added by #17,
which extracted it out of `ToolLoop`); on `main` the identical logic is inline in
`lib/nest/agents/agent/tool_loop.ex` (`query_peer/4`, `await_query_result/4`,
`wait_for_idle/5`, `read_last_assistant_after/3`). `PeerQuery` is called from
exactly two places:

* `ToolLoop.run_query_agent/2` (`tool_loop.ex:385`, `:393`) — the **blocking**
  `agents-query` tool call, and
* `AsyncWaiter.query_wait/6` (`async_waiter.ex:145`) — the **async** `async:
  true` mode.

Both share the same wait, so a fix in `PeerQuery` fixes both modes. The
`agents-spawn` and `agents-batch` waits do **not** share it (see "What the fix
must not break").

## Today

### The mechanism, step by step

`agents-query` (blocking) runs in the turn's tool worker, never in the calling
agent's GenServer (`tool_loop.ex:385-399`):

1. `PeerQuery.run/5` (`peer_query.ex:52`) starts one wall-clock deadline
   (`System.monotonic_time(:millisecond) + timeout`, `:55`) and calls
   `query_peer/6`.
2. `query_peer/6` reads the target's messages and captures
   `pre_count = length(messages)` (`peer_query.ex:67-69`). This is a snapshot of
   how many messages the target has **before** the query is sent.
3. It subscribes to the target's PubSub topic (`:71`,
   `Broadcasts.topic/2` = `"agent:<space_id>:<name>"`).
4. It sends the prompt with `Nest.Agents.chat(space_id, target, prompt)`
   (`:72`) — the **human** chat path (`agents.ex:267-279` → `Agent.chat/4`,
   `agent.ex:395` → cast `{:chat, prompt, nil, nil}` → `Callbacks.chat_or_queue/4`,
   `callbacks.ex:75`). For an idle target this starts a turn immediately; for a
   busy target it queues the entry (`Inbox.enqueue_user_message/4`,
   `inbox.ex:158`) and returns `:ok` either way.
5. It waits for `{:chat_status, %{status: "idle"}}` on the target's topic
   (`peer_query.ex:97-101`), re-polling every `@wait_slice_ms` (250ms, `:34`)
   and bounded only by the deadline (`:91-96`). The wait is bounded by elapsed
   time, never by a message count (issue #20).
6. On the first idle it reads `read_last_assistant_after/3`
   (`peer_query.ex:122`): the target's **newest** assistant message with
   `index >= pre_count` (`:128`), returning `{:ok, text}`, `{:error, :no_text}`
   for an assistant with no text parts (`:143`), or `:pending` (keep waiting)
   when there is none (`:129-135`).

So the wait has exactly two inputs: "the target said idle" and "there is an
assistant message whose index is at or after my pre-query count". It has no way
to say "**my** message was delivered and this assistant answers **it**".

### The transient idle the `:idle` drain emits

#15 guarantees no transient idle *on the boundary path* (`iterate/1` drains in
place, phase stays `:generating`; `boundary.ex:61`, `transitions.ex:501-512`).
But the **`turn end → idle`** path still passes through idle, and it is the
common path when the query arrives after the peer's last boundary:

* `Response.branch(:finalize, …)` (`response.ex:143`) →
  `finalize_or_defer/4` (`:156`) enters `:idle` and returns actions
  `[… , {:append, assistant}, {:finalize, :clean}, {:drain_inbox}]`.
* `Turn.run/5` (`turn.ex:55`) runs those actions. The machine is now `:idle`, and
  `turn.ex:64` **broadcasts the `:idle` status** *before* the `{:inbox_drain}`
  follow event is settled (`:66-67`).
* Only then does `Transitions.do_step(%{phase: :idle}, {:inbox_drain, …})`
  (`transitions.ex:227`) → `deliver_inbox/3` (`:424`) → `start_chat/3` (`:429`)
  append the query's user message and start the query's turn (status back to
  `:streaming`, `turn.ex:64`).

So the peer is broadcast `idle`, then `streaming`, in quick succession, and the
query's own turn is the one that follows. The waiter accepts the **first** idle.

## Failure case A — the peer's own answer is returned as the query's answer

Concrete, deterministic-in-shape sequence (peer `P`, caller `C`; `P` is streaming
the final text of its own turn `T0`):

1. `C`'s tool worker calls `PeerQuery.run(space, "P", prompt, timeout)`.
2. `pre_count = N` is captured (`peer_query.ex:67-69`). `T0`'s final answer has
   not been appended yet.
3. `C` subscribes to `P`'s topic, then `Agents.chat(space, "P", prompt)` casts
   the prompt. `P` is `:streaming`, so `chat_or_queue/4` (`callbacks.ex:75-81`)
   queues it (`kind: :user`, `from: nil`, `mode: nil`) and broadcasts
   `chat:inbox`.
4. `T0`'s HTTP response lands: `Response.branch(:finalize, …)` appends `T0`'s
   answer, enters `:idle`, and emits `{:drain_inbox}`. `Turn.run/5` broadcasts
   `:idle` (`turn.ex:64`).
5. `C`'s waiter receives `{:chat_status, idle}` and immediately calls
   `read_last_assistant_after(space, "P", N)` (`peer_query.ex:97-101`,
   `:122`). `P`'s newest assistant with `index >= N` is **`T0`'s answer**
   (step 4). The read returns it (`:128-131`), the waiter returns `{:ok, T0_text}`,
   unsubscribes, and `C` gets `T0`'s answer as the query result
   (`tool_loop.ex:393`, `:413`).
6. `P` then settles `{:inbox_drain}` and runs the query's own turn (`:idle` →
   `deliver_inbox` → `start_chat`). Its answer is appended and **discarded** —
   nobody is waiting for it any more.

Why this is not a narrow race: step 3→4 spans `P`'s **entire final HTTP
request** (the whole streaming of `T0`'s last response — seconds). Any query
that arrives in that window is queued and then delivered at the `:idle` drain,
and the waiter reads on a status broadcast that `Turn.run/5` emits *before* the
query's turn even starts, so the read sees `T0`'s answer (it is the newest
assistant until the query's own request lands).

**Variant A′ — a compaction summary as the answer.** If `P` is compacting when
the query is queued, the compaction appends its summary assistant (`index >= N`)
and the waiter reads the *summary* as the query's answer. Same shape, worse
content.

## Failure case B — a timeout although the peer received the query

`read_last_assistant_after/3` only accepts a *new assistant message after
`pre_count`*. Anything that makes that message never appear turns a delivered
query into a timeout:

* **B1 — the cast is silently dropped.** If `P` is in a broken status
  (`:model_missing`, `:needs_repair`, `:context_overflow`, `:compaction_failed`,
  `:compaction_loop_detected`), `chat_or_queue/4`'s fallthrough
  (`callbacks.ex:82-87`) logs a warning and **drops** the message, while
  `Nest.Agents.chat/5` already returned `:ok` (`agents.ex:267-279`). `P` never
  goes idle, the waiter never reads, and the deadline produces
  `{:error, {:timeout, ms}}` (`peer_query.ex:91-96`). The caller cannot tell
  "queued, will answer" from "dropped".
* **B2 — starvation.** A peer that is busy and stays busy past the timeout (its
  own long turn, or — with #15 — a peer that keeps receiving messages at each
  boundary and so keeps starting new turns and never reaches `:idle`) makes the
  wait expire. This is #15's noted "idle-based waits are unaffected but can be
  starved". Honest framing: B2 is partly a legitimate timeout, but it shares the
  root cause — the tool has no delivery confirmation, only "did the peer go
  idle".

The deterministic, controllable timeout is **B1** (a broken peer is a status
you can set exactly).

## Candidate designs

### A. A sender-known correlation id the target announces on delivery

The waiter generates an id before sending. The id rides on the queued inbox
entry and the target announces it — together with the index at which the
delivered user message actually landed — when that message is appended. The
waiter then requires an assistant message **after that index**.

Shape:

* `Inbox.entry` (`inbox.ex:213`, `put_entry/5`) gains a `correlation_id`
  (string or integer; normalised like `from`/`mode`). `Inbox.serialize/1`
  (`inbox.ex:186`) adds `"correlation_id"`. **This is additive and invisible in
  the browser**: `InboxPanel.jsx` builds its React key and its labels from an
  explicit field list (`kind`, `from`, `timestamp`, `content`, `mode`) and
  `agentInbox.js` reads only `kind`/`content`; unknown keys are ignored.
* The query needs a delivery path that carries the id. The human `chat` path
  (`Agent.chat/4`) has no entry parameter, so add a query-specific enqueue (or a
  `deliver_query` call) that enqueues `kind: :agent`, the prompt, and the id. See
  "Open decisions" for the label question.
* On delivery, the target announces. The announcement must be tied to the
  **actual append**, not the drain: `Transitions.start_chat/3`'s `:fits` branch
  already emits `{:append, user}` (`transitions.ex:435-438`); add an action
  `{:announce_delivery, ids}` immediately after it, executed by
  `Turn.Executor`, broadcasting e.g.
  `{:chat_delivery, %{ids: ids, index: idx}}` where `idx` is the stamped index
  of the appended user message. (Tying it to the append, not the drain, is what
  makes the `:needs_compaction` park — appended later, at the compaction's
  `resume_with_pending` — and the `:cannot_compact` `{:restore_inbox, entries}`
  path behave correctly: no announcement, so the waiter keeps waiting / times
  out honestly.)
* `PeerQuery` waits for `{:chat_delivery, %{ids: ids, index: d}}` containing its
  own id, then for the first assistant message with `index > d`, and returns its
  text. The deadline and the `:no_text`/read-failed tags are unchanged.
* A **combined drain** (several queued entries in one user message) shares one
  appended index, so the announcement carries a list of ids; every waiter whose
  id is in the list anchors on the same `d` and reads the same answer — which is
  correct, because the combined message is answered once.

Trade-offs: new state on the entry and on the wire (additive), a new broadcast
event, and one extra machine action plus executor clause. In return it is
**robust by construction**: no content heuristics, and it handles combined
drains, the over-cap pointer offload (`inbox.ex:245-264`, where the prompt is
not in the transcript at all), the compaction park, and the restore path.

### B. Content/index correlation

The waiter finds the delivered user message whose content contains its prompt
and requires an assistant message after *that* index. Honest assessment: it is
foolable, in ways that are not exotic.

* The drained content is a **combination with labels** (`Inbox.combine/1`,
  `inbox.ex:230-232`: `"[Message from agent \"x\"]\n<content>"` joined with
  blank lines). A substring match can hit another queued entry's content.
* A **repeated prompt** (the same question asked twice, or a prompt that is a
  common phrase) anchors on the older message, so the waiter reads an older
  answer, or nothing new → `:pending` → timeout.
* A **synthetic user message** can appear after `pre_count`: the
  truncation/silent re-prompt appends a user nudge (`response.ex:127-131`,
  `ContextReminder.build_user_notice/2`). It is a user message and can be
  mistaken for the delivery.
* The peer's **own answer can echo the prompt**, so matching "contains the
  prompt" can anchor on an assistant, not the delivered user message.
* **Over-cap drains are replaced by a pointer** (`inbox.ex:245-254`): the prompt
  text is not in the transcript at all, so the waiter never finds its message →
  timeout.
* Matching on the message **tag** (`{:user, _}`) rather than content is not
  enough — a tool message is also a wire-`user` message
  (`MessageList.last_wire_role/1` maps `:tool` → `:user`), and there is no id to
  disambiguate.

There is also a cost: `Agents.chat` gives the sender no index and no delivery
confirmation, so discovery means polling the peer's transcript — i.e. more
`get_messages` GenServer calls, in the very read path where failure case A
lives. Rejected as the primary mechanism; usable only as a last-resort fallback
if no id is available (it should not be).

### C. Build the blocking query on the #17 async machinery

What #17 gives: with `async: true` the tool returns immediately and a supervised
`AsyncWaiter` delivers exactly one noted result to the caller's inbox
(`async_waiter.ex`, `deliver/4`). The *result delivery* is correlated (one
waiter, one delivery, keyed by the caller's pid). But the *answer* is produced
by the same `PeerQuery.run/5` (`async_waiter.ex:145`), so the async path
inherits failure case A and B unchanged. **(c) does not fix the answer by
itself.**

What building the blocking query on the async machinery *would* change:

* **One wait implementation.** Both modes already share `PeerQuery`, so a fix
  there already covers both; (c) buys a single *timeout budget and result
  builder* on top, not correctness.
* **The tool's user-visible contract, if the blocking path literally waits on
  the caller's own inbox:** it cannot. The caller is **busy** running this very
  turn, so `Inbox.handle_delivery/3` (`inbox.ex:130-133`) would *queue* the
  result until the turn ends — and the turn cannot end until the tool worker
  returns. Deadlock. The blocking path must wait on a direct hand-off to the
  worker pid (the way `Children`/`AsyncWaiter` forward `{:spawn_agent_result,
  name, …}`), not on the caller's inbox.
* **Timeout semantics:** in the async path a timeout is a normal result
  delivered as `[agents-query timed out]` (`async_waiter.ex:154-160`); in the
  blocking path it is an `is_error: true` tool result
  (`SubAgentResults.query_failure({:timeout, ms}, target)`,
  `tool_loop.ex:416`). Keeping the blocking contract means the worker must
  translate the waiter's outcome back to the error text — doable, but it is
  extra moving parts for no extra correctness.

Verdict: a reasonable **refactor** (one wait, one deadline, one builder) but not
a fix; worth doing only alongside A, and only if it genuinely reduces code.

### D. Considered and rejected — route the query through `agents-send` and reply

`Agent.deliver_message/3` (`agent.ex:409`) → `Inbox.handle_delivery/3`
(`inbox.ex:122-140`) returns the delivery disposition synchronously
(`{:ok, :delivered}` / `{:ok, :queued}` / `{:error, reason}`). Using it for the
query would fix **B1** (the sender would learn "queued" vs "dropped"), and it
gives the id a natural home. But to get the *answer* the peer would have to send
a reply back to the caller — a request/response protocol that needs its own
correlation (the reply must name the query) and a place for the busy caller to
receive it. Bigger change than A, and it does not by itself fix A. Worth taking
only as a small companion for B1 (see "Open decisions"), not as the correlation
mechanism.

### Recommendation

**Take A.** A sender-known correlation id carried on the queued entry, with the
target announcing the id plus the appended index on delivery, and the waiter
requiring an assistant message after that index. It is the only candidate that
is robust by construction; it is additive on the wire (the browser ignores the
new key); and, because both modes share `PeerQuery`, it fixes blocking and async
together. Implement the wait change once in `PeerQuery`.

Keep (C) as an optional follow-up refactor *after* A lands (one wait/timeout
budget for both modes), and treat (D)'s disposition as a separate small fix for
B1. Do not use B as the mechanism.

## What the fix must not break

1. **#15's turn-boundary delivery.** A query to a busy peer must still be
   queued and delivered at the next boundary (in place, phase stays
   `:generating`, no transient idle). Do **not** "fix" the wait by suppressing
   the `:idle` broadcast, removing the `:idle` drain, or adding a second
   signal that changes when the drain fires. `Boundary.drain?/1` and
   `deliver_inbox/3`/`start_chat/3` keep their current semantics; the
   announcement is additive.
2. **The `agents-send` path.** `Inbox.handle_delivery/3` (`kind: :agent`, the
   `[Message from agent "…"]` label), the `chat:inbox` payload, and
   `InboxPanel`'s rendering and optimistic-row retraction
   (`agentInbox.js`, `agentCacheMessages.js`) must keep working. Any new entry
   key must be additive (it is: the browser reads explicit fields).
3. **The tool-facing result text the LLM sees.** `SubAgentResults.query_success/3`,
   `query_failure/2` (the `:timeout` / `:no_text` / `:read_failed` / `:chat` /
   `:not_found` tags and the catch-all), `spawn_*`, and the async notes must stay
   in sync. An error must **never** come back as a successful empty (`""`)
   result — the existing rule in `tool_loop_query_error_test.exs`. If the wait's
   return shape changes, update `build_query_result/4` (`tool_loop.ex:413-417`)
   **and** `AsyncWaiter.query_wait/6` (`async_waiter.ex:145-165`) together, and
   keep the async note (`[agents-query result|failed|timed out]`) matching the
   blocking body.
4. **The wall-clock bound.** One `System.monotonic_time/1` deadline for the
   whole query, never a message count (issue #20). The read/setup time counts
   against it (`peer_query.ex:54-57`), and the poll uses
   `receive … after min(@wait_slice_ms, remaining)` (`:110-113`) so a chatty
   target can neither extend nor exhaust the budget. The correlation wait must
   not add an unbounded `receive`, and the deadline must start before the
   pre-count read, as today.
5. **The sub-agent (`agents-spawn`) and `agents-batch` waits, and `agents-wait`.**
   `agents-spawn`/`agents-batch` wait on `{:spawn_agent_result, name, …}` /
   `{:spawn_agent_error, name, …}` forwarded by the parent's `Children`
   sub-machine (`sub_agent.ex`, `children.ex`, `executor.ex`'s
   `{:notify_worker, …}`) — already name-keyed and correct. Do not touch
   `Children`/`SubAgent`/`BatchLoop`. `agents-wait` (`WaitLoop`) waits on idle
   **by design** (it wants the first idle and reports the target's stop message)
   and does not send a message, so the own-turn/new-turn ambiguity does not
   apply; leave it alone.
6. `mix precommit` clean; the Elixir suite stays under 5s; no test prints to the
   console.

## Tests

### Unit (deterministic; Mimic-stubbed `Nest.Agents`, like `tool_loop_query_error_test.exs`)

Pin the failure and the fix without a real peer:

* **A is not resolved by the peer's own answer.** Stub `Nest.Agents.get_messages`
  to return the peer's pre-delivery answer (`index = 5`) on the first read; send
  `{:chat_status, %{status: "idle"}}`; assert `PeerQuery.run/5` does **not**
  return the peer's answer (it stays pending / times out). Then send
  `{:chat_delivery, %{ids: [id], index: 6}}` and stub `get_messages` to return
  `[peer_answer(5), user(6), query_answer(7)]`; assert `{:ok, "query answer"}`.
* **Combined drain.** Two ids in one `{:chat_delivery, …}` → both waiters anchor
  on the same index and read the same assistant.
* **Timeout / `no_text` / read-failure tags** unchanged for a delivery that never
  arrives (B1: a broken peer never goes idle → timeout).
* **Inbox id plumbing.** `put_entry/5` normalises the id (string/nil);
  `serialize/1` includes `"correlation_id"`; `handle_delivery/3` (the
  `agents-send` path) is unchanged (nil id).

### Machine / executor (pure, like `machine_boundary_delivery_test.exs`)

* `deliver_inbox/3` emits `{:announce_delivery, ids}` **after** the append, on
  both the `:idle` (`transitions.ex:227`) and `:generating` (`:325`) drain
  paths; the machine stays pure and `Machine.validate!/1` passes.
* It does **not** announce when `start_chat/3` takes `:needs_compaction` (the
  message is parked; the announcement comes from the resume append) or
  `:cannot_compact` (entries are restored via `{:restore_inbox, entries}`).
* `Boundary.drain?/1` is unchanged (a regression pin).

### Integration (real agents, DataCase, no sleeps, ≤500 ms fences, no console output)

* **"a blocking `agents-query` to a genuinely busy peer returns the query's own
  answer, not the peer's"**: start a coordinator and a real peer (MockClient);
  make the peer genuinely busy with an in-flight turn whose own final answer is a
  distinct scripted text; run the blocking `agents-query` in a task; drive the
  peer's own turn to completion so its answer lands with the query queued; assert
  the tool result equals the **query's** scripted answer and **never** the
  peer's.
  *Determinism:* do not rely on the natural read-before-query-answer race.
  Force the ordering — e.g. gate the query's own turn (a tool call that blocks
  on a test-controlled gate, no sleep) so the peer's own answer is the only
  assistant that can land before the read. If that cannot be made deterministic,
  say so and pin the pre-fix failure at the unit level only (the unit test above
  is deterministic), and keep the integration test asserting the fixed contract
  (`result == query_answer and result != peer_answer`).
* **"a query to a busy peer is delivered at the boundary and answered"**: peer
  genuinely busy in a tool batch; query issued; release the tool; assert the
  query's answer (this pins #15's boundary delivery for the query path and must
  not regress).
* **B1**: a broken peer → the tool reports a timeout error, not a success and not
  the peer's stale text.

Both integration tests must drive the coordinator's turn to completion and wait
for the peer to be idle before the test ends (the `await_delivery` pattern in
`tool_loop_async_test.exs`), so no background process touches the sandbox after
check-in.

## New tracking issues this implies

1. **`Nest.Agents.chat/5` returns `:ok` for a silently dropped message.** A
   broken-status peer logs and drops (`callbacks.ex:82-87`) while the caller
   sees `:ok`; a query then times out with no explanation (B1). Either give the
   query path a delivery call that returns the disposition (D's
   `deliver_message/3` shape) or make the drop observable to the caller.
2. **Idle-based waits can be starved** (#15's known limit): a peer that keeps
   receiving messages at boundaries never reaches `:idle`, so `agents-query`
   and `agents-wait` can wait longer than the peer's actual work. Tracked, not
   fixed here.
3. **The query's delivered message is labelled `[Message from the user]`**
   because it goes through the human `chat` path, even though it comes from an
   agent. If the fix routes it through the agent delivery path, that changes the
   target's LLM-visible prompt (see "Open decisions").
4. **The inbox entry has no stable id** (`InboxPanel.jsx` keys the list by the
   whole entry, so two identical entries collide). A `correlation_id` would give
   the panel a stable key; relates to #27's inbox work.

## Open decisions (for the implementation review)

* **The entry's `kind` and the label.** If the query enqueues as `kind: :agent`
  (via a `deliver_query`-style call), the target sees
  `[Message from agent "<caller>"]` instead of `[Message from the user]`. That
  is arguably more accurate for a peer query, but it is a change to the target's
  prompt, so it needs an explicit decision. If we keep `kind: :user`, the label
  stays and only the id is added.
* **Announcement transport.** A new `{:chat_delivery, …}` PubSub event is the
  obvious carrier. An alternative is to piggyback on the existing `chat:message`
  broadcast (the appended user message) with the ids attached; that keeps the
  event count down but couples the announcement to the message payload's shape.
  A new event is cleaner and additive.
* **Id type.** A `reference()` is unambiguous but not serializable; a monotonic
  integer or a random string is wire-safe. The id only ever needs to be echoed
  back to the same caller, so a random string (e.g. a short hex) is enough, and
  it can be shown in the inbox panel or left opaque.

## Boundaries deliberately not taken

* **Do not change `agents-wait`.** It wants the first idle and reports the stop
  message; the own-turn/new-turn ambiguity does not apply.
* **Do not suppress the `:idle` broadcast or remove the `:idle` drain.** The
  transient idle is the signal the bug lives on, but other consumers (and the
  wait's own progress) rely on the real turn end; the fix is correlation, not
  signal removal.
* **Do not make the blocking query wait on the caller's own inbox.** The caller
  is busy; a delivered message is queued until the turn ends — deadlock.
* **Do not touch the spawn/batch child correlation.** It is already name-keyed
  and correct.
* **Do not use content matching as the primary mechanism.** It is foolable in
  ordinary cases (see B), and every poll is an extra read in the buggy path.
* **Do not change the LLM-visible result text.** The error/timeout/empty
  contract is pinned by `tool_loop_query_error_test.exs`.
