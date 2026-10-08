# Issues #26, #29, #27 — parked-message visibility, the reserve-exhausted strand, and the human queue

Design note for three follow-ups from #15 (`notes/issue-15-boundary-delivery.md`,
"Known limits found in review") and the PR #28 whole-artifact review
(`notes/review-pr28.md`). #26 and #29 are the same class of bug — a message that
exists on the machine but on no wire payload; #27 is the queue's quadratic wire
cost plus its missing bound. This note decides each and lists the tests.

Status: **design only, no code changed.** Line references are to the tree at the
time of writing (`boundary-delivery` merged into `main`); they are by function
where a line could drift.

## The shared seam

`Turn.Executor`'s `{:drain_inbox}` is the single point that consumes
`state.live.inbox`:

```
Transitions.iterate/1   (boundary, #15)  ─┐
Transitions.:idle drain (handle_delivery) ─┼─▶ {:drain_inbox}
turn end / fail / stop / unblocked        ─┘        │
                                                    ▼
                          Executor.execute({:drain_inbox}, state)
                            content = Inbox.combine_and_offload(entries, state)
                            mode    = applied_mode(state, entries)
                            state.live.inbox = []          # ← consumed here
                            Broadcasts.inbox(state, [])    # ← count 0 on the wire
                            → {:inbox_drain, entries, content}
                                                    │
                                                    ▼
                          Transitions.deliver_inbox(m, entries, content)
                            user = Dispatch.build_user_message(content, m.work.ctx.mode)
                            start_chat(m, {:user_message, user}, entries)
                              :fits            → append + iterate
                              :needs_compaction→ park on m.pending_user_message
                              :cannot_compact  → {:restore_inbox, entries} + blocked
```

Every "park" decision runs **after** the consumption. So from the moment the
executor clears the inbox until the compaction resumes:

* `chat:inbox` reports count 0 with an empty list (and the client's optimistic
  row was already retracted when the queue entry first appeared),
* the transcript has nothing (the message is deliberately not appended before
  the compaction), and
* `pendingMessageCount` / `pending_messages` read only `state.live.inbox`,

i.e. the human's message is in **no** payload, even though the agent is visibly
`:compacting`. #26 is the visibility half of that; #29 is the same "nowhere"
state reached by a branch that skips even the resume. Both are fixed at this
seam, which is why they are designed together.

---

## #26 — a parked message is invisible on the wire while it waits

### Today

`start_chat/3`'s `:needs_compaction` branch
(`lib/nest/agents/agent/machine/transitions.ex`) does:

```elixir
:needs_compaction ->
  Compaction.stage(%{m | pending_user_message: entry}, nil, nil)
```

`entry` is `{:user_message, {:user, %User{}}}` for the drain path (built by
`Dispatch.build_user_message/2`, so it carries the `[mode: X]\n` prefix, the
`[Message from the user "<id>"]\n…` framing already combined into its text, and
`metadata: %{"mode" => mode}`) and `{:user_message, %User{}}` for a human
`{:chat_request, …}`. The `%User{}` has **no `from`** — the sender was on the
inbox entry, and the inbox entry is gone. The mode is recoverable from
`metadata["mode"]`; the sender is not.

`Compaction.resume/1` → `resume_with_pending/1` appends the parked message once
the commit lands and re-enters `:generating`, so the message is lossless on the
normal path — it is only *invisible* while it waits.

### Option (a) — surface the parked message in the inbox payload

Two sub-shapes, both requiring the client to render a "yours, waiting" entry:

1. **Serialize the built `%User{}` as a synthetic entry.** `kind: "user"`,
   `from: nil`, `mode: metadata["mode"]`, `content:` the text part with the
   `[mode: X]\n` prefix stripped. Cost: the content still carries the combined
   `[Message from the user "…"]` / `[Message from agent "…"]` framing (the
   panel renders every other entry *verbatim*, before framing), and the sender
   is genuinely lost, so the panel would say "From an unidentified user" for a
   message the user just sent. This is a degraded rendering of state the server
   actually had a moment earlier.
2. **Park the original entries too** (they are in scope at the
   `:needs_compaction` branch as `inbox_entries`) on a new machine field, and
   serialize `parked ++ serialize(inbox)`. Full fidelity, but it is a
   display-only mirror of state that is already represented by
   `pending_user_message`; two representations of one message is exactly the
   kind of redundant state this codebase avoids, and it must be kept in sync on
   every resume/loop-ack/retry.

Either way `status_payload/1`'s `pendingMessageCount: length(live.inbox)` and
`IntrospectionHandler.runtime_fields/1`'s `pending_messages` need the parked
entry folded in, and the client's `InboxPanel` needs a `parked` marker.

### Option (b) — peek-then-consume

The drain **peeks**: it computes `content` and applies the mode, returns
`{:inbox_drain, entries, content}`, but leaves `state.live.inbox` alone and does
not rebroadcast. A new `{:consume_inbox, entries}` action — emitted by
`start_chat/3`'s `:fits` branch — is what clears the inbox and broadcasts the
empty frame. The `:needs_compaction` path consumes nothing, so the entries stay
queued and visible (count > 0) for the whole compaction; `resume` re-drains them
once the context has shrunk, and `:fits` consumes them.

This is lossless by construction (the message is never off the queue until it is
appended) and preserves full fidelity with **zero** new wire shape and **zero**
client change: the panel already renders the entries, the count already rides
`chat:status`, and the optimistic-row retraction already keyed off the entry.
It also makes `{:drain_inbox}` and `{:restore_inbox}` mutually exclusive, which
retires the restore path (below).

What it costs, spelled out:

* **`{:restore_inbox, entries}` is retired.** It exists only to undo the
  executor's eager clear on the `:cannot_compact` branch. With peek-then-consume
  the entries were never cleared, so the `:cannot_compact` branch is just
  `enter_blocked(m, :context_overflow)` + the overflow broadcast; `:restore_inbox`
  and its executor clause and its `Machine.@actions` entry are deleted (the
  action-coverage guard test moves with it). The entries stay queued while the
  agent is blocked, and `{:unblocked}`'s existing `{:drain_inbox}` re-attempts
  them — the same retry the restore gave, with no extra action.

* **"One mode per delivery" is unchanged in rule, but its *timing* moves.** The
  mode is still resolved by `Executor.applied_mode/2` at the drain (it must be:
  `deliver_inbox` builds the user message from `m.work.ctx.mode`, and the
  machine cannot resolve a mode against the vocation). Under (b) the peek still
  applies it, so on a *deferred* delivery the mode is applied and published even
  though no consume happens — which is already true today (the drain applies the
  mode before parking). The rule "the most recent human entry with a mode wins"
  is now evaluated fresh at **each** peek: if a newer human entry arrives during
  the compaction, the resume's peek re-resolves the winner, so the batch is
  still delivered under one mode, just a later one. Worth one sentence in
  `Inbox`'s "One mode per delivery" section: the winner is resolved at delivery
  attempt time, not at enqueue and not once-per-batch-for-life.

* **`pending_user_message` survives for the human `{:chat_request, …}` path
  only.** That path (`Transitions` `:idle` `{:chat_request, entry}` →
  `start_chat(m, entry, nil)`) has no inbox entries, so on `:needs_compaction`
  there is nothing left in the queue to re-deliver; it must still park the built
  message, and `resume_with_pending/1` still appends it. Concretely the branch
  becomes conditional:

  ```elixir
  :needs_compaction ->
    parked = if inbox_entries in [nil, []], do: %{m | pending_user_message: entry}, else: m
    Compaction.stage(parked, nil, nil)
  ```

  So (b) retires the parking machinery for the **inbox** path, not for the chat
  request. `held_user/1` and `resume_with_pending/1`'s append arm stay.

* **The compaction retry/loop paths need a "give up" shape.** This is the real
  cost of (b) and the reason it "needs its own review". Today the parked message
  is *out of the queue*, so a path that wants to stop trying just appends it and
  moves on. Under (b) the entries are still in the queue, so **every** drain
  re-attempts them, and a drain that re-attempts a message which does not fit
  re-enters `:needs_compaction` → `Compaction.stage`. Three paths need care:

  * **`Compaction.resume/1`** — `resume_with_pending/1` currently branches on
    `pending_user_message`. Add a drain-in-place arm: when the inbox is non-empty
    (`ctx.inbox_count > 0`, the `Boundary` accessor) the resume enters
    `:generating`/`:chat` and emits `{:drain_inbox}` **without** passing through
    `:idle`. This preserves the #15 "no transient idle, no spurious
    `{:finalize, :clean}`" property for a boundary delivery that needed a
    compaction (the case the design note explicitly claims holds). The `nil` arm
    (nothing parked, inbox empty) keeps today's `:idle` + `{:finalize, :clean}` +
    `{:drain_inbox}`.
  * **`:loop_ack`** — today appends `held_user/1` before the drain *precisely so
    the ack does not re-enter the compaction decision*. Under (b) `held_user` is
    nil on the inbox path, so the bare `{:drain_inbox}` would re-stage a
    compaction and loop (operator-gated by the ack's `loop_count: 0` reset, but
    still a loop the ack was meant to break). The ack needs a **consume-and-append
    drain shape**: consume the entries and append the combined user message
    without calling `start_chat` (no preflight, no dispatch) — i.e. today's
    behaviour, with the executor building the message from the entries. This is
    the "second drain shape" #15 deferred; #26 is the case that makes it
    earn its keep. It can be one action, e.g. `{:drain_inbox, :append}` (the
    executor's existing drain helper builds `content`; the `:append` mode skips
    `deliver_inbox` and appends `Dispatch.build_user_message(content, mode)`).
    The chat-request arm keeps `{:append, {:user, held}}`.
  * **`:reserve_exhausted`** — see #29. On the inbox path the entries stay queued
    (visible) and the branch must **not** drain (a drain would re-stage and
    loop); it should enter a blocked phase. On the chat-request path it appends
    the held message. On the no-message paths (manual `/compact`, workspace
    notice, retry with an empty inbox) it keeps today's `:idle`.

* **`Turn.drain_inbox/1`'s `:delivered | :queued` reply gets more accurate.**
  It infers from `state.live.inbox == []` after the settle. Under (b) that is
  empty iff the delivery actually consumed, so a drain that parks for a
  compaction now correctly reports `:queued` to `handle_delivery/3` (today it
  reports `:delivered` even though the message is parked). No caller depends on
  the old value, but it is a wire-visible reply change worth a test.

### Recommendation: **(b)**

(b) is the only option that is lossless by construction and keeps full fidelity
(`from`/`kind`/`mode`) with no new wire shape and no client change, and it fixes
#29's inbox-path strand for free. The alternatives are worse in the way the
"never quietly hide state" rule cares about:

* **(a) shows the user a lower-fidelity message.** The parked built `%User{}`
  cannot name its sender and its text is already LLM-framed, so the panel would
  render "From an unidentified user" over `[Message from the user "alice"]\n…`.
  That is *visible*, but it is a visibly wrong rendering of state the server had
  one step earlier, which is worse than a delay.
* **(a)'s full-fidelity variant re-introduces redundant state** (entries parked
  beside the built message) with a sync obligation on every resume/loop-ack,
  i.e. it pays (b)'s complexity cost without (b)'s simplicity.
* **(b) retires code.** `{:restore_inbox}`, the executor's clear-and-rebroadcast
  in `{:drain_inbox}`, and the inbox-path half of `pending_user_message` all go
  away; the message's home is its home until it is delivered.

The honest cost of (b) is the consume-and-append drain shape for `:loop_ack`
(and the resume drain-in-place), which is more machine surface than #15 carried.
If the team judges that too much for this area, **(a) sub-shape 1 is the
contained fallback** (one payload field + one client branch + a `parked` marker);
it should be chosen knowingly as a fidelity downgrade, not as a "no new state"
win.

### Tests (#26, deterministic, no sleeps, ≤500 ms fences)

Machine (`machine_boundary_delivery_test.exs`, or a new sibling at the file cap):

* `:fits` from a drain emits `{:consume_inbox, entries}` **before** `{:append, _}`
  and `:iterate`; from a chat request (`inbox_entries == nil`) it emits no
  consume.
* `:needs_compaction` from a drain emits neither consume nor restore and leaves
  `pending_user_message == nil`; from a chat request it sets `pending_user_message`.
* `:cannot_compact` from a drain emits **no** `{:restore_inbox, _}` (pin the
  removal).
* `Compaction.resume/1` with `pending_user_message == nil` and `ctx.inbox_count > 0`
  emits `{:drain_inbox}` in `:generating`/`:chat` with no `{:finalize, _}`; with
  `inbox_count == 0` it keeps `:idle` + `{:finalize, :clean}` + `{:drain_inbox}`.
* `:loop_ack` with a non-empty inbox emits the consume-and-append shape and no
  `{:drain_inbox}`; with an empty inbox it keeps today's `{:append, {:user, held}}`
  / bare `{:drain_inbox}` cases.
* `guard_test.exs`/`executor_test.exs`: the action↔executor-clause coverage moves
  with `:consume_inbox` added and `:restore_inbox` removed.

Executor (`turn/executor_test.exs`):

* `{:drain_inbox}` leaves `state.live.inbox` unchanged and broadcasts no
  `chat:inbox` frame; returns the `{:inbox_drain, entries, content}` follow event.
* `{:consume_inbox, entries}` clears the peeked entries and broadcasts exactly
  one `chat:inbox` with `count: 0`.
* `Turn.drain_inbox/1` returns `:queued` (not `:delivered`) when the drained
  message parks for a compaction.

Integration (`turn_acceptance_test.exs`): park a real tool batch with the
`Mimic.stub(Nest.Agents, :send_message, …)` release valve, queue a human
message, release, and assert the `chat:inbox` **frame sequence** is
`queued (count 1)` → still `count 1` while `:compacting` → `count 0` after the
commit, and that the delivered `chat:message` carries the entry's verbatim text
and the human's mode. Assert on payloads, not on an exact status list (the
channel test helper double-subscribes, per review-pr28 finding 2).

### Tracking issues implied by (b)

* The consume-and-append drain shape is a new action-vocabulary member; record
  why it exists (the give-up paths) in `Boundary`'s or `Compaction`'s moduledoc.
* `Machine`'s dead `resume` field (review-pr28 "Repo and process state") — delete
  opportunistically while this area is open, or track it.

---

## #29 — `:reserve_exhausted` strands the parked message

### Today

`Compaction.do_stage/2` (`lib/nest/agents/agent/machine/compaction.ex`):

```elixir
{:error, :reserve_exhausted} ->
  machine = Phase.enter(m, :chat, :idle)
  {:ok, [{:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}], machine}
```

It enters `:idle` with **no** `{:drain_inbox}`, and `m.pending_user_message`
stays set. The executor already consumed `state.live.inbox`, so the parked
message is on no queue and in no payload; the drain that would have delivered it
is the one that was skipped. Reachability: `system_size + suffix >= reserve` at
the same moment preflight said `:needs_compaction` — a system prompt that nearly
fills the 20 % reserve. Rare, but it is the same class as the `:loop_ack` drop
fixed in #15.

Note the branch is reached from every `Compaction.stage/3` caller:
`start_chat/3` (both the drain and the chat-request path), `:preflight_result
{:refuse, _}`, `:compact_request`, `retry_compaction`, and the `:workspace_notice`
`:needs_compaction` arm.

### Minimal fix (current consume-first design)

`:loop_ack` is the precedent: it appends `held_user/1` **before** its
`{:drain_inbox}` so a parked message is kept in the transcript instead of
dropped, and a refused append surfaces as `{:append_result, :invalid, _}` rather
than a silent loss. Reuse it here:

```elixir
{:error, :reserve_exhausted} ->
  machine = Phase.enter(%{m | pending_user_message: nil}, :chat, :idle)

  case Phase.held_user(m) do
    nil -> {:ok, [{:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}, {:drain_inbox}], machine}
    user -> {:ok, [{:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil},
                   {:append, {:user, user}}, {:drain_inbox}], machine}
  end
```

Two mechanical points:

* `held_user/1` is currently **private** in `Machine.Transitions` (beside
  `unwrap_user`'s delegation). Move it to `Machine.Phase` next to
  `unwrap_user/1` and have both callers use it; that is the "helper to reuse"
  the issue names, and `Phase` is already the single held-shape table.
* Clear `pending_user_message` (the `%{m | pending_user_message: nil}`), as
  `:loop_ack` does, so a later resume cannot append the same message twice.

Why append rather than re-drain: `:reserve_exhausted` means the model cannot fit
the system prompt + compaction request into its reserve, i.e. the model is
fundamentally too small. Re-draining would re-run `start_chat` → `:needs_compaction`
→ `Compaction.stage` → `:reserve_exhausted` in a tight synchronous loop. The
append is the "keep it, answer it next turn" disposition `:loop_ack` uses, and
the overflow broadcast already tells the operator to change the model.

### Interaction with #26's chosen design

* **If #26 is (b)**: the inbox path no longer parks, so the parked message only
  exists on the **chat-request** path. The fix above is exactly the chat-request
  arm. The inbox-path arm needs no append (there is nothing parked); instead the
  branch must **not** drain (the entries are still queued and visible), and it
  should `enter_blocked(m, :context_overflow)` rather than `:idle`, so a later
  drain does not immediately re-stage the same failing compaction. The message
  is visible in the inbox the whole time, which is the outcome #26 wants; the
  remaining decision is only status (`:context_overflow` vs today's `:idle`).
  The `nil`/empty-inbox paths (manual `/compact`, workspace notice, retry with
  nothing queued) keep today's `:idle` + broadcast. So the branch becomes a
  three-way `cond` on `held_user != nil` / `ctx.inbox_count > 0` / otherwise.
* **If #26 is (a) or unchanged**: the inbox path still parks, so the fix is the
  two-arm `held_user` version above for both paths.

Either way #29 is small; (b) just relocates which arm is "append" and which is
"block", and makes the inbox-path strand disappear as a side effect.

### Tests (#29)

* Machine (`machine_test.exs` "compaction decisions" or a sibling): `do_stage`'s
  `:reserve_exhausted` on the chat-request shape (`pending_user_message` set)
  emits `{:append, {:user, _}}` **before** any drain, clears
  `pending_user_message`, and does not emit `{:restore_inbox, _}`; on the
  no-message shape it emits the broadcast + drain and stays `:idle`. Reuse the
  existing `held_shapes` fixture table from the `:loop_ack` test so every
  `Phase.unwrap_user/1` shape is covered.
* Machine: an unknown held shape is logged (`unrecognized pending_user_message`)
  and treated as nothing held — already the `:loop_ack` contract; assert it for
  this branch too (capture_log, inclusion only).
* Integration: a chat request that is held across a compaction which then hits
  `:reserve_exhausted` is not stranded — assert the message appears in the
  transcript (or, under (b), that the inbox still carries the entry) and that
  the agent ends in a defined status. No sleeps; drive the compaction failure
  deterministically with the existing compactor stubs.

---

## #27 — the human queue bypasses the cap and rebroadcasts the whole list

### Today

* `Inbox.@max_inbox_size` (100) bounds `handle_delivery/3` only;
  `enqueue_user_message/4` (the human path, from `Callbacks.chat_or_queue/4`)
  never refuses, so the queue is unbounded for the whole turn and the Agent heap
  holds every entry.
* `Broadcasts.inbox/2` sends `%{messages: serialized_list, count: n}` on every
  enqueue, so `n` frames cost `~n²·s/2` bytes to every subscriber. With the cap
  bypassed, `n` is unbounded; with the cap enforced it is bounded to
  `100²/2·s ≈ 5050·s` bytes (≈ 1 MB for 200-byte frames, ≈ 50 MB for 10 KB
  frames).

Human typing self-limits this (Send clears the input, each send is a round trip)
and the app has no rate limiting on any channel event, so a bound on *this*
queue does not bound a spammed idle agent's DB growth.

### Option (a) — bound the human path, make the refusal visible

Give `enqueue_user_message/4` the same bound and refuse *visibly* instead of
silently. Because `Agent.chat/4` is a cast, the refusal cannot ride the
`chat:message` reply (the channel already answered `:ok`); it must be a
broadcast:

```elixir
# Inbox.enqueue_user_message/4 → {:ok, state} | {:refused, state}
if length(state.live.inbox) >= @max_inbox_size do
  {:refused, state}          # caller logs + broadcasts
else
  {:ok, broadcast(put_entry(state, from, content, :user, mode))}
end
```

`Callbacks.chat_or_queue/4`'s busy arm logs `Logger.warning("[agent:…] refusing a
chat message: inbox full (100)")` and
`Broadcasts.notification(space, name, %{type: "inbox_full", content: content,
message: "…"})`. Keep the cap check inside `Inbox` (one home for the cap) and
return a tagged result so the `Inbox` test can assert the refusal without a
broadcast; `Callbacks` owns the log + notification (it already owns the
"dropped while broken" log).

**Browser half.** `assets/js/channels/agent.js`'s `chat:notification` handler
gains a branch: when `payload.type === "inbox_full"`, call
`store.retractUserMessage(agentId, payload.content)` (the optimistic row the
send left behind — `retractOptimisticRow` already matches newest-first by
content, the same logic the queue retraction uses) and
`store.setWaitingForResponse(agentId, false)` before `setNotification`. The
payload must therefore carry `content`; without it the client cannot match the
row and the refusal leaves a phantom bubble. `NotificationBanner` already
renders `notification.message`, so the refusal is visible with no new component.
This is the only option that fixes the **root cause** (unbounded growth) and,
with it, bounds the quadratic traffic to a small absolute number.

### Option (b) — incremental inbox broadcasts

Replace the whole-list frame with deltas. In the current design the list only
ever grows by appends and is emptied by a drain (plus the restore, which #26(b)
retires), so the protocol is just `op: "append"` / `op: "clear"`; the
`init`/`chat:inbox` request-reply keeps sending the full list as the recovery
frame. Wire cost drops from `~n²·s/2` to `~n·s` (the append frames) plus the
recovery frame; a `count` still rides every frame and `chat:status` so the panel
can tell it is stale.

**Browser half.** `setAgentInbox` splits into `appendAgentInbox` (push one
entry, run the retraction for that entry) and `clearAgentInbox` (empty the
list), with the request-reply / `init` path keeping a full replace. The recovery
story needs care under "never quietly hide state": a missed **append** leaves the
list short of `pendingMessageCount`, which the panel already shows as
`max(count, list.length)` and repairs via its `onFetch` on open; a missed
**clear** leaves stale rows with count 0, which the current `max(count, length)`
would keep showing. So the clear handler must be authoritative on the count
(e.g. trim the list to `min(count, length)` on a status frame, or always
re-request the full list when the count drops below the list length). This is
strictly more client machinery than (a) for a bounded-but-uglier traffic shape,
and it does **not** bound the queue, so it does not fix the growth.

### Option (c) — channel-level rate limiting / back-pressure

A token bucket per socket (per topic) on `chat:message` (and the other mutating
events) in `AgentChannel`, with a visible refusal and a `chat:notification`. It
is the general fix for "any channel event can be spammed" — the issue explicitly
notes an idle agent can be spammed into unbounded DB growth — but it is broader
than this queue: it touches every channel, needs config, a stateful limiter per
socket, and UX for the refusal, and it does not by itself make the inbox frame
incremental. It belongs in its own issue.

### Recommendation: **(a)**, with **(b)** as an optional follow-up and **(c)** as a separate issue

(a) bounds the root cause (the queue) and makes the refusal visible, which is
what the "no silent drop" rule demands; it is a small, testable change in
`Inbox`/`Callbacks` plus one client branch. (b) is a real but secondary
optimisation: with the cap enforced the quadratic term is bounded to a small
absolute number, so (b) only matters if the 10 KB-message worst case is judged
too large — and it is only *safe* to add incrementally if the client gains the
missed-clear recovery above. (c) is the correct long-term DoS fix but is a
space-wide concern, not this queue's; recommend tracking it separately rather
than smuggling it into #27.

### Tests (#27)

* `Inbox`: `enqueue_user_message/4` at `@max_inbox_size` returns the refusal
  and does not append; at `cap - 1` it appends. Deterministic (build the state
  with `@max_inbox_size` entries directly; no sleeps).
* `Callbacks`: a busy agent at the cap logs the refusal (capture_log,
  inclusion-only) and broadcasts one `chat:notification` with
  `type: "inbox_full"` and the verbatim `content`; a busy agent below the cap
  queues and broadcasts one `chat:inbox` (as today).
* JS store: the `chat:notification` handler with `type: "inbox_full"` retracts
  the matching optimistic row and clears `waitingForResponse`; a non-refusal
  notification leaves the rows alone. `NotificationBanner` renders the
  `message`. All synchronous `vi.waitFor` fences ≤ 500 ms; no console output.
* Channel integration: push `chat:message` at the cap and assert the
  `chat:notification` frame reaches the socket (the same double-subscription
  caveat as #26's integration test — assert on the payload, not a frame count).

### Tracking issues implied by #27

* **Channel rate limiting / back-pressure** (option (c)) as its own issue — the
  general "any channel event can be spammed" concern, including the idle-agent
  DB-growth vector the issue names.
* The `Inbox` moduledoc's "the human queue is unbounded" paragraph becomes
  stale under (a); correct it and the `handle_delivery/3` / `enqueue_user_message/4`
  docstrings to state the one bound and the visible refusal.

---

## Cross-cutting

* **All three change the same seam**, so land them in the order #26 → #29 → #27
  (or #26+#29 together): #26's shape decides #29's arms and whether #27(b)'s
  delta protocol needs a `remove` op.
* **No behaviour may be hidden.** Every branch above that drops or defers a
  message either leaves it on the wire (inbox entry, transcript) or emits a
  visible notification/error. The one place this is still imperfect is the
  `:invalid`-append loss #15 already documented ("Known, accepted residual
  exposure"); #26(b) actually shrinks it, because an append that never consumed
  leaves the entries queued for the next attempt.
* **The `Callbacks` missing catch-all `handle_cast`** (review-pr28 nit 5) is
  adjacent: #27(a) adds a refusal path to `chat_or_queue/4`, so it is the right
  moment to decide whether the loud `FunctionClauseError` for the old 2-/3-tuple
  cast stays (recommended, per the project's crash-clearly rule) and to say so in
  a comment.
* **`agents-query` starvation** (a peer that keeps receiving messages keeps
  starting turns, so an idle-based wait can be starved) is named in #15 and
  still untracked; #26(b) does not change it, but the tracking issue is owed.
