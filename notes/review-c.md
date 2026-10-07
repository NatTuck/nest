# Adversarial review — commit `703bad5` "Deliver queued inbox messages at the turn boundary (#15)"

Reviewer: `review-c`. Branch `boundary-delivery`, reviewed revision `703bad5`
(read via `git show 703bad5:<path>`).

**Tree state during review:** `HEAD == 703bad5`, and `git diff HEAD -- lib test`
was empty — only `assets/**` (10 files) was modified by the other agent. So every
Elixir/`test/` result below is the reviewed commit, not an in-flight edit.
(Task D's in-flight edits — `inbox.ex`, `callbacks.ex`, `turn/executor.ex`,
`agent_channel.ex`, `agents.ex`, `agent.ex`, plus their tests — landed in the tree
*after* my logged runs and probes; a re-run of the four files afterwards was
61 tests / 0 failures. All file:line references below are to `703bad5`.) All
probes were run with `MIX_ENV=test mix run --no-start <script>` from `/tmp`
(nothing in the repo was modified except this report and the test logs under
`notes/test-runs/`).

**Verification run** (`notes/test-runs/review-c-boundary.log`,
`notes/test-runs/review-c-inbox.log`):

* `mix test test/nest/agents/agent/machine_boundary_delivery_test.exs
  test/nest/agents/agent/machine_test.exs test/nest/agents/agent/turn_acceptance_test.exs
  test/nest/agents/agent/machine_structure_test.exs` → **60 tests, 0 failures, 1.0s**, no log output.
* `mix test test/nest/agents/agent/inbox_test.exs
  test/nest/agents/agent/tool_loop_send_agent_test.exs
  test/nest/agents/agent/turn/executor_test.exs test/nest/agents/agent/guard_test.exs`
  → **52 tests, 0 failures, 0.3s**.
* `mix credo` → clean (4023 mods/funs, no issues). `transitions.ex` is 438 code
  lines / 656 total (caps 500/700).

The core rule itself I could **not** break: the drain cannot fire with an
unanswered `Part.ToolUse`, an in-flight request, or a half-appended batch, and I
could not construct a wedge or a silent drop specific to it (details in
"Attacks that held"). The findings below are a doc/behaviour mismatch I *can*
demonstrate, a pre-existing loss path the note's losslessness argument misses, and
test/doc accuracy issues.

---

## F1 — should-fix (doc): the "compaction boundary not taken" claim is false; the drain *does* fire at the `context-compact` resume

`notes/issue-15-boundary-delivery.md:229-232`

> **The compaction turn's `:iterate`**: it does not call `iterate/1` at all, and a
> user message cannot be injected into a compaction request. A message arriving
> during a compaction is delivered when the compaction turn ends (**unchanged**).

The compaction *request* turn indeed never calls `iterate/1`. But the **resume after a
`context-compact` commit** does, and the drain fires there:

1. `Response.compact_only/5` (`machine/response.ex:191-204`) carries
   `{:compact_tool, [assistant_msg, synthetic], n, max}` and appends **neither**
   message before staging.
2. `Turn.Commit.active_segment/6` → `append_entry_tail/2`
   (`turn/commit.ex:80`) puts `[assistant(compact tool_use), tool(synthetic)]` at the
   tail of the new segment, and `ensure_assistant_tail/2` adds no ack for a carried
   entry.
3. `Compaction.resume/1` → `true` branch (`machine/compaction.ex:138-140`) →
   `resume_machine/2` → `Phase.enter(..., :chat, :generating, :http)` + `init_turn`
   → action `:iterate`.
4. `Transitions.iterate/1` (`transitions.ex:479-484`): the tail is the synthetic
   **tool** message, so `unpaired_tail_tool_uses/1` is `[]` → `deliver_at_boundary?/1`
   is true (inbox non-empty, `force_finalize` false, tag `:tool`) → `[{:drain_inbox}]`
   **instead of** dispatching the post-compaction request.

Evidence (probe 1 + probe 2, both pure):

```
post-commit tags: [:user, :assistant, :tool]
unpaired_tail_tool_uses: []
last_wire_role: :user

resume actions: [{:broadcast, :status, nil}, :iterate]
resumed kind/phase: {:chat, :generating}
ctx.inbox_count: 1
iterate actions: [{:drain_inbox}]          # <-- drain, not dispatch
next kind/phase: {:chat, :generating}
```

Same for `Compaction.compaction_failed/3` with a carried `{:compact_tool, ...}`
(`compaction_failed` → `resume_machine` → `:iterate`, and `compact_only` never
appended the assistant, so the pre-compaction tail is still a tool result):

```
compaction_failed actions: [{:broadcast, {:compaction_error, "Compaction failed: :boom"}, nil}, :iterate]
iterate after failure: [{:drain_inbox}] -> {:chat, :generating}
```

Also wrong in the same bullet, the other way: on the `resume_with_pending/1` path
(`machine/compaction.ex:144-161`) the resume appends the **held** user message and
then `:iterate`s with a `{:user, _}` tail, so a message queued during that
compaction is *not* delivered "when the compaction turn ends" — it waits for the
next boundary, exactly as before. (I verified the tail check excludes it; no probe
needed, but it is the same `deliverable_tail?/1` clause.)

**Assessment of the behaviour itself:** safe. The wire is legal (`[..., tool, assistant(ack), user]`
passes `Nest.LLM.Preflight.validate_request/1` — probe 5), the delivered turn gets a
fresh budget (`start_chat/3` → `init_turn/2`), and delivering before the next request
is the design's whole point. So the fix is to the note (and, ideally, to the
"Boundaries deliberately not taken" list): the compact-tool resume is a **taken**
boundary, and it is a behaviour change, not "unchanged".

## F2 — should-fix (pre-existing, but the note's losslessness section is incomplete): a held `pending_user_message` is silently dropped by `:loop_ack`

`transitions.ex:90-95`, `turn/executor.ex:305-316`, note `:96-107` and `:157-171`.

`start_chat/3`'s `:needs_compaction` branch parks the drained message on
`pending_user_message` (`transitions.ex:418-419`) — and the new machine test
`machine_boundary_delivery_test.exs:116-143` asserts exactly that ("held … not
lost"). But the compaction loop-breaker drops it:

```elixir
def do_step(%{phase: :compaction_loop_detected} = m, :loop_ack) do
  machine = enter(%{m | loop_count: 0, pending_user_message: nil, mid_turn_entry: nil}, :chat, :idle)
  {:ok, [{:drain_inbox}], machine}
```

The executor already cleared `state.live.inbox` and handed the entries to the follow
event, so after `:loop_ack` the content exists nowhere. Reproduction (probe 4):

```
chat_request@loop3 actions: [{:broadcast, {:compaction_loop, "compaction isn't reducing the conversation", 3, 3}, nil}]
  phase=:compaction_loop_detected pending_kept=true
loop_ack actions: [{:drain_inbox}] phase=:idle pending=nil
```

Reachable: three consecutive compaction retries (`:retry_compaction` is the only
thing that increments `loop_count` without appending progress) leave `loop_count == 3`;
the next needs-compaction `start_chat` — from a drained inbox message *or* a human
chat request — trips `count > @max_consecutive_compactions` in `Compaction.stage/3`.
So the loss is **pre-existing and identical for the `:idle` drain** (I am not blaming
the commit for introducing it), but it is not covered by the note's
"Known, accepted residual exposure" (which only analyses the `:invalid` append) and it
contradicts the acceptance criterion at note `:292` ("No message is lost"). Minimal
honest options: (a) amend the note + the test comment to say the held message is
lossless *unless the loop breaker trips*, or (b) on `:loop_ack`, re-deliver the held
message instead of dropping it (keep `pending_user_message` and append it before the
`{:drain_inbox}`), which is a small, self-contained change in `Transitions`.

## F3 — nit (test fragility): `ConversationSize.size(projected) + 8_191` silently mirrors `Nest.Tokens.Reserve`'s floor

`machine_boundary_delivery_test.exs:126-127`

```elixir
projected = m.work.ctx.messages ++ [Dispatch.build_user_message("queued", "chat")]
limit = ConversationSize.size(projected) + 8_191
```

The branch is only forced because `Dispatch.preflight_decision/2` uses
`Reserve.compaction_reserve(limit) = max(0.20·limit, 8_192)`
(`lib/nest/tokens/reserve.ex:56-76`): slack 8_191 < floor 8_192 ⇒ `size + reserve > limit`
⇒ not `:fits`, and the shape (two user turns, a system message present) keeps it out of
`:cannot_compact`. The estimator half is fine and stable (the test builds the identical
message the transition builds, so the sizes match exactly — verified by reading
`Dispatch.build_user_message/2` and `PreFlight.fits_with_reserve?/3`), but `8_191` is a
hard-coded mirror of `@compaction_floor` in another module. If that floor is ever
lowered (the moduledoc advertises it as a single knob), the test flips to `:fits` and
fails with a misleading `assert next.kind == :compaction`. Minimal fix: derive it, e.g.

```elixir
size = ConversationSize.size(projected)
limit = size + Reserve.compaction_reserve(size) - 1
```

or at least assert the precondition (`assert Dispatch.preflight_decision(projected, limit) == :needs_compaction`)
so a drift fails with a clear message instead of an unrelated assertion.

## F4 — nit (test): 2000 ms fences with no measured justification

`turn_acceptance_test.exs:565` (`statuses_until_idle/1`) and `:575` (`assert_request/0`).
`SMELLS.md:41-47` caps test timeouts at 500 ms unless the comment carries *measured*
numbers; the comment at `:550-556` gives none. The whole file uses 2000 ms, and
`inbox_test.exs:34-46` uses 500 ms for the same kind of wait, so 500 ms is the
established safe value here. (`refute_receive {:llm_request, _}, 50` at `:470` is fine —
a negative assertion needs to wait, and 50 ms is the recommended value.)

## F5 — nit (test comment): the status assertion's comment mis-attributes the third `"streaming"`

`turn_acceptance_test.exs:441-446` says the third `"streaming"` is
"the delivered message's turn, started in place". It is not: it is the
`:executing_tools → :generating` transition inside `Transitions.tool_results/2`
(`transitions.ex:572-578`), broadcast *before* the delivery. The delivery itself
broadcasts **nothing** — the status never changes — which is precisely what the test
proves. As written the comment implies the delivery produces a status change, i.e. the
opposite of the contract. Fix the comment (e.g. "…→ streaming (back from the tool
batch; the delivery itself changes no status) → idle").

## F6 — nit (doc): the note's Acceptance bullet contradicts its own "Other decisions" bullet

`notes/issue-15-boundary-delivery.md:289-291` ("with the status never leaving
`:streaming`") vs `:249-257` ("The status can leave `:streaming` on the delivery path
when the new turn does not fit and `Compaction.stage/3` runs: the agent goes
`:compacting`") and vs `:126-131` ("the phase (and therefore the observable status)
never changes"). The code takes the second path: `start_chat/3` → `:needs_compaction`
→ `Compaction.do_stage/2` → `Phase.enter(..., :compaction, :generating, :http)`, and
`Machine.status_for/1` (`machine.ex:208`) maps that to `:compacting`. The acceptance
bullet needs the same qualification the "Other decisions" bullet already has.

## F7 — nit (doc): the justification for `ctx.inbox_count` rests on a false premise

`notes/issue-15-boundary-delivery.md:269-271`: "the machine struct itself is at its
field cap (`Machine.Work` exists for that reason), so it cannot live there."
`Machine.Work` has **12** fields (`machine/work.ex:23-36`) and credo's cap is
`StructFieldAmount max_fields: 16` (`.credo.exs:154`); `Machine` has 10. So a 13th
`Work` field (or a 11th `Machine` field) would be legal — the field cap explains why
`Work` exists, not why `inbox_count` cannot live on it. The defensible reasons for the
ctx are the ones the note gives elsewhere: `Turn.build_ctx/2` is the single producer
and `Turn.prepare/1` (`turn.ex:162-169`) rebuilds it before every step, so the value
cannot go stale. Worth correcting so the next reader doesn't "fix" it onto `Work`
without noticing the freshness argument.

Related (nit, and explicitly accepted by the author): `inbox_count/1`'s
default-to-0 (`transitions.ex:516-517`) means a *production* ctx that lost the key
would silently disable delivery instead of failing loudly — against the project's
"fail loudly / never quietly hide missing data" convention. It is pinned today by the
integration test, so this is only a note.

## F8 — nit (doc): `chat_state.ex` still attributes the drain to `Inbox`

`lib/nest/agents/agent/chat_state.ex:132-141` (rewritten by this commit): "…combined
into a single user message … and drained by `Nest.Agents.Agent.Inbox` at the next turn
boundary". `Inbox` only queues and combines (`Inbox.enqueue/3`,
`Inbox.combine_and_offload/2`); the drain is `Turn.Executor.execute({:drain_inbox}, …)`
/ `Turn.drain_inbox/1`, as `Inbox`'s own moduledoc (`inbox.ex:8-11`) says. The sentence
is in the rewritten hunk, so it is fair game: point it at the executor.

## F9 — nit (doc): two other notes still assert the pre-#15 invariant

* `notes/enforce-mesages-seq-invariants.md:145`: "A user message is only accepted at
  idle — the channel and `Callbacks.chat_or_drop/3` reject it mid-turn — so this append
  can only be the turn-opening append and cannot race a live turn."
* `notes/pr19-review-findings.md:83`: "The live-path `{:repair, _}` clause in
  `Repair.classify_live/2` really is a last-resort guard, and it cannot fire mid-turn
  because `agent_channel.ex:313-321` rejects `chat:message` …".

Both are now false for the `agents-send` path: `Transitions.iterate/1` appends a user
message mid-turn without the channel being involved (that is the point of the commit).
The commit's design note enumerates the *code* comments to fix but not these two. One
line each (or a "historical" marker) would do.

## F10 — nit: the `{:assistant, _}` deliverable tail looks unreachable in production

Condition 3 also accepts `{:assistant, _}`, and
`machine_boundary_delivery_test.exs:198` calls it "the other deliverable tail". I
enumerated every `:iterate` in `:generating`/`:chat` (`transitions.ex:304`, `:481-484`,
`:599-615`, `:223-225`, `Response`'s reprompt branch, `Compaction.resume/1` →
`resume_machine/2`, `Compaction.compaction_failed/3` → `resume_machine/2`) and every
way an assistant can be the tail with `unpaired_tail_tool_uses/1 == []`:

* carried `{:tool_call, assistant, …}` → the assistant *has* a `Part.ToolUse` → preflight, no drain;
* carried `{:assistant_response, …}` → `Compaction.resume/1` sends it to `:idle` + `{:finalize, :clean}`, never `:iterate`;
* the truncation/silent reprompt → the tail is the nudge **user** message;
* notice pairs (`NoticePairInjector.build_pair/3`) are always followed by another append in the same action list.

So the branch is defensive, not a live boundary. Not a defect (and it is *useful*: with
an assistant tail the alternative is `dispatch_http/1` →
`Preflight.validate_request/1` → `:no_trailing_assistant` → `fail_turn`, verified in
probe 5), but the test comment and condition 3 read as if a "final assistant ack"
boundary exists. Worth one clarifying clause so nobody hunts for it.

## F11 — nit (test fixture): the boundary fixture looks like a worker is in flight

`machine_boundary_delivery_test.exs:268-279` builds the `:generating` fixture with
`worker_kind: :http, worker_ref: make_ref()`. At every real `:iterate` boundary the ref
is `nil`: `Phase.enter/4` clears `worker_ref`/`active_worker` on every transition into
`:generating` (`machine/phase.ex:27-41`), and `:iterate` is only emitted after the
append that follows that `enter` (`tool_results/2`, `recover_interrupted_tool/1`,
`start_chat/3`, `resume_machine/2`). Using a live-looking ref in the fixture slightly
weakens the claim being tested ("nothing is in flight"); `worker_ref: nil` would
document the real precondition. Cosmetic.

## F12 — nit (maintainability): the commit spends most of `transitions.ex`'s remaining total-line budget

`lib/nest/agents/agent/machine/transitions.ex` went 613 → **656 total lines** against
the custom `SourceFileMaxLines` cap of 700 (438/500 code lines) — 87 → 44 lines of
headroom. `Machine.Compaction`'s moduledoc already cites this budget as the reason it
exists. Not a violation (credo is clean), just a note that the next feature touching
this file has very little room and should expect to move code out.

---

## Attacks that held (what I tried to break, and why it survived)

1. **Wedge: `{:drain_inbox}` yielding no follow event while the machine sits in
   `:generating` with no worker and no pending event.** Held. `Turn.settle/2` calls
   `prepare/1` first, and `prepare/1` sets `inbox_count: length(state.live.inbox)`
   (`turn.ex:162-169`, `:206-208`); `run/5` then hands that *same* state to
   `Executor.run_all/2`, which reads `state.live.inbox` (`executor.ex:305-316`). The
   inbox is only written by the agent process (`Inbox.enqueue/3` via the `deliver_message`
   call, and the executor's own drain/restore), and there is no await between the
   decision and the action, so `ctx.inbox_count > 0 ⟹ entries are drained`. The `:iterate`
   action being mailbox-deferred only makes the ctx *fresher*. The acceptance test
   reaching `idle` also exercises this end to end.
2. **A drained append refused as `:invalid` (which would lose the entries).** Held for
   conditions 1–3. `start_chat/3` only appends when `preflight_decision(messages ++ [user], limit) == :fits`,
   i.e. `size(messages ++ [user]) + reserve <= limit`. The bridge ack append then sees a
   *smaller* list, so `PreFlight.check_passed/2` is `:fits`; the user append can only
   return `:cannot_compact` if the system alone exceeds `limit - reserve` (impossible
   after `:fits`) or if the shape is a compaction no-op, which requires the last user
   message to be at index 0 — not the tool/assistant-tail shapes this path admits when
   the system message is index 0. I also checked the extra ~8-token ack cannot overflow
   a provider window: `:fits` leaves `reserve >= 8_192` of headroom
   (`Nest.Tokens.Reserve`), and `Preflight.validate_request/1` is wire-format only.
3. **Loss / duplication / reordering.** Held. The drain is the single consumer: it clears
   the inbox and hands the entries to exactly one follow event; `{:inbox_drain, …}` has
   exactly two clauses (`:idle` any kind `transitions.ex:211-214`, `:generating`+`:chat`
   `:311-314`) and both are only reachable from their matching emit site (the chat
   `iterate`, or `Inbox.handle_delivery/3`'s `status == :idle` branch); `{:restore_inbox, entries}`
   restores the list in order and cannot race (same settle step, single process).
   `run_all/2` halts on the append's follow event, so a failed append never leaves a
   stray `:iterate` behind. Ordering through the tool batch is deterministic:
   `ToolLoop.run_batch/2` runs sub-agent calls sequentially in input order
   (`tool_loop.ex:112-116`), so the acceptance test's `first_at < second_at` is not a
   flake source.
4. **`force_finalize`.** Held. Only `Response.force_finalize/1`'s two branches set it,
   and both append a synthetic tool result and `:iterate`, so the guard is exactly what
   keeps the queued message waiting for the real turn end; `init_turn/2` clears it for
   the delivered turn. `Response.branch(:force_finalize, …)` then finalizes to idle and
   the existing `:idle` drain delivers.
5. **`List.last(messages(m))` vs `MessageList.last_wire_role/1`.** Held — the tag check
   is required (`last_wire_role/1` maps `{:tool, _}` → `:user`, `message_list.ex:387-397`,
   which would exclude exactly the case to allow), and the fallbacks are safe:
   `{:system, _}`, `{:compaction, _}`, `nil` (empty list) all return false and fall
   through to the unchanged `dispatch_http/1`.
6. **Purity of the new table code.** Held. The new clause calls
   `Dispatch.build_user_message/2` (a `DateTime.utc_now()` timestamp — identical to the
   pre-existing `:idle` clause) and `start_chat/3` → `Phase.enter/4`/`init_turn/2`; no
   effect, no `phase:`/`kind:` write outside `Phase`.
7. **`ctx.inbox_count` placement.** The only production producer is `Turn.build_ctx/2`
   (the one test caller, `agent_oversized_system_test.exs:87`, reads named keys), and
   `Dispatch.spawn_ctx/2` only copies it into a worker request context, so no
   serialization/API-log/key-set assumption is affected. A missing key is impossible in
   production.
8. **Test value (judging assertions, not the author's claim).** The new machine tests are
   real: test 1 fails without the feature (it asserts `{:drain_inbox} in actions` and no
   `{:spawn_http, _}`); test 2 fails if the `force_finalize` guard or the `is_integer/1`
   guard is dropped (the `nil` case relies on it); test 3 fails if `deliverable_tail?/1`
   admits `{:user, _}` or if the check is hoisted out of the `[]` branch. The acceptance
   test is real too: with the delivery deferred to idle the status sequence would end
   `…, "idle"` and the drained message would land *after* the final assistant, so both
   `statuses_until_idle() == [...]` and `drained_index == final_index - 1` fail; the
   second `assert_request/0` plus `refute_receive {:llm_request, _}, 50` pin "exactly two
   requests", which the rejected "end the turn, then start a new one" alternative would
   violate. No `Process.sleep`, no `async: false`, no single-assertion or
   duplicated-setup tests, no log output. `assert_received` (no wait) is safe because the
   inbox broadcasts are published from the agent process before the final idle status
   broadcast and local PubSub delivery is ordered per publisher.

## Minor observations, not worth their own finding

* `inbox_test.exs:37` still titles the busy-target test "…drains all queued messages
  together **on idle**"; the drain now happens at the first boundary (in that test the
  synthetic `:streaming` status has no worker, so idle is still where it lands). Title
  only.
* `:loop_ack`'s `mid_turn_entry` branch (`transitions.ex:86`) is dead: nothing in `lib`
  ever sets `mid_turn_entry` (only reads and resets). Pre-existing, unrelated to #15.
* `Compaction.resume/1`'s `pending_notice` clause precedes the carried-entry clauses, so
  a carried `{:assistant_response, …}` is dropped when a workspace notice is pending.
  Pre-existing, unrelated to #15 (flagging only because I found it while tracing the
  resume paths).
