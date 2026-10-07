# Adversarial review — task D1 + the review-c follow-ups (branch `boundary-delivery`, uncommitted)

Reviewer: `review-d1`. Scope: the **uncommitted Elixir work** in the working tree of
`/home/nat/Code/nest` on branch `boundary-delivery` (HEAD = `703bad5`), i.e. task D1
(human messages during a turn, server half) plus the review-c follow-ups (`:loop_ack`,
`Machine.Boundary`, F3/F4/F5/F10/F11, resolved mode at drain). `assets/**` is another
reviewer's; I only read it where an Elixir/JS contract had to be checked, and I touched
nothing in the tree except this report and `notes/test-runs/review-d1-*.log`.

## What I ran (full output, no grep/head/tail)

```
$ mix compile --force --warnings-as-errors      # notes/test-runs/review-d1-compile.log
Compiling 186 files (.ex)
Generated nest app

$ mix test <the 45 touched/related files from notes/task-d1-report.md>
                                                # notes/test-runs/review-d1-run2.log
Running ExUnit with seed: 460806, max_cases: 24
360 tests, 0 failures  (1.7s)

$ mix test <the 6 D1 files>                     # notes/test-runs/review-d1-run1.log
90 tests, 0 failures  (1.2s)

$ mix credo                                     # notes/test-runs/review-d1-credo.log
Checking 406 source files ... 4046 mods/funs, found no issues.
```

Probes were run as pure scripts from `/tmp/nest-review-d1/` with
`MIX_ENV=test mix run --no-start <script>` (nothing in the repo written). Probe output is
quoted verbatim below.

The tree is green and credo-clean, matching the author's report. **The structural claims I
was asked to attack hold** (details in "Attacks that held"); the findings below
are a remotely-triggerable agent crash, an unbounded queue, a silent drop in the
`:loop_ack` fix, a UI-transparency gap for a parked message, and doc/test nits.

---

## D1-1 — should-fix: a non-string `chat:message` content crashes (and permanently kills) the Agent

`lib/nest_web/channels/agent_channel.ex:321-326`

```elixir
def handle_in("chat:message", %{"content" => content} = payload, socket) do
  ...
  mode = Map.get(payload, "mode")
  sender = socket.assigns.current_user.username
```

`content` is whatever the JSON payload carried — there is no `is_binary/1` guard, while the
sibling clause three lines below (`handle_in("change_model", %{"model" => model_params})
when is_map(model_params)`, `:349`) shows the convention. A payload of
`{"content": {"a": 1}}` now **queues** on a busy agent (D1) and blows up later, inside the
Agent process, when the drain combines the entries:

```
$ MIX_ENV=test mix run --no-start /tmp/nest-review-d1/probe_a.exs
--- A1: idle path, Dispatch.build_user_message(map) ---
A1 RAISES: Protocol.UndefinedError: protocol String.Chars not implemented for type Map...
--- A2: queued path, Inbox.combine_and_offload([map content]) ---
A2 RAISES: Protocol.UndefinedError: protocol String.Chars not implemented for type Map...
```

The raise is in `Inbox.combine/1` (`inbox.ex:214-216`, `"#{entry.content}"`), called from
`Turn.Executor.execute({:drain_inbox}, …)` (`executor.ex:306-316`), which runs inside
`Turn.settle/2` inside `handle_cast`/`handle_info`. There is no `rescue` anywhere on that
path (`callbacks.ex` has none; `Agent.handle_cast/2` is a bare delegate,
`agent.ex:651`), and the Agent is `use GenServer, restart: :temporary` (`agent.ex:33`), so
the process dies **and is not restarted** — the whole agent is gone (the registry entry is
removed; the UI's channel dies with it) from one malformed frame. The channel has already
replied `{:ok, %{}}`, so the client believes the message was accepted.

* Counterexample: join an agent's channel, send `{"event":"chat:message","payload":{"content":{"a":1}}}`
  while the agent is `:streaming` → reply `{:ok, %{}}`, `chat:inbox` count 1, then the
  agent process exits with `Protocol.UndefinedError` at the next boundary drain.
* Reachability: **the idle-path half is pre-existing** (A1 above: a map content already
  crashed the agent before this branch), but D1 widens it — a busy agent used to answer
  `{:error, "agent_busy"}` for that frame and now accepts and queues it.
* Minimal fix (channel-local, consistent with `change_model`):
  ```elixir
  def handle_in("chat:message", %{"content" => content} = payload, socket)
      when is_binary(content) do ... end
  def handle_in("chat:message", _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_content"}}, socket}
  ```
  (The fallback clause also covers a payload with no `"content"` key, which today matches
  no clause at all: `handle_in/3` is an `@optional_callbacks` entry with no default in
  `Phoenix.Channel`, so the channel server raises inside its own `handle_in/3` call —
  `deps/phoenix/lib/phoenix/channel/server.ex:332`.) A `mode`/`from` type guard would
  close D1-7 at the same time.

## D1-2 — should-fix: the human path bypasses `@max_inbox_size` with nothing else bounding it

`lib/nest/agents/agent/inbox.ex:145-153` (`enqueue_user_message/4` — no cap, by design),
`inbox.ex:209-212` (`broadcast/1` re-sends the **whole** serialized list on every
enqueue), `callbacks.ex:76-77`.

The task report flags this ("The human path ignores `@max_inbox_size` … Flagged for your
call"). My call: it needs a bound, because the amplification is quadratic in the number of
queued frames:

* each `chat:message` frame while busy appends one entry and rebroadcasts
  `Broadcasts.inbox(state, Inbox.serialize(state.live.inbox))` (`broadcasts.ex:213-219`) —
  the full list, to every subscriber of the agent topic;
* so `n` frames cost `~n²·s/2` bytes of PubSub traffic (`s` = entry size). 2 000 small
  frames (≈100 B each) ≈ 200 MB of broadcast and 2 000 full serializations; 20 000 frames
  ≈ 20 GB. No rate limiting exists anywhere in `lib/` (grep for `rate_limit`/`throttle`:
  nothing), and the D2 half deliberately keeps Send enabled while the agent is busy — that
  is the feature — so the browser does not bound it either.
* The agent's turn can legitimately run for dozens of requests (that is the premise of
  #15), so the queue keeps growing for the whole turn; nothing drains it early.
* Also unbounded memory in the Agent heap: `state.live.inbox` is never trimmed.

Minimal fixes, in order of preference: (a) give `enqueue_user_message/4` the same
`@max_inbox_size` bound and, when full, **drop nothing and say so** — e.g. keep the entry
but broadcast a `chat:error`/inbox-full notice so the human sees it (the channel's reply
cannot carry it: the cast has no reply channel, and the channel's own status read is
non-authoritative by design); or (b) make `Broadcasts.inbox` incremental (append/remove
deltas) so the quadratic term disappears, and document the remaining unbounded growth as
accepted. The moduledoc currently says only "a human message is queued even when the cap
is reached rather than silently dropped", which is honest about the *drop* but not about
the *growth*.

## D1-3 — should-fix: `held_user/1` silently drops a held shape that `Phase.unwrap_user/1` supports

`lib/nest/agents/agent/machine/transitions.ex:618-632` vs
`lib/nest/agents/agent/machine/phase.ex:96-107`

`Phase.unwrap_user/1` is the documented normalizer for a held entry and knows four shapes
(`{:user, _}`, `%User{}`, `{:user_message, %User{}}`, `{:user_message, {:user, _}}`) plus
the legacy `{content, mode}` tuple ("Legacy held-message shape … (pre-machine fixtures)",
`phase.ex:104`). `held_user/1` re-implements a *subset* of that table and maps anything
else to `nil`, i.e. "nothing held" — so the `:loop_ack` fix silently drops exactly the
messages it was written to save whenever the parked value is one of the shapes it does not
list. Counterexample (probe B, verbatim):

```
held={:user_message, {:user, ...}}   -> actions=[:append, :drain_inbox] pending_after=nil phase=idle
held={:user_message, %Nest.Messages.User{...}} -> actions=[:append, :drain_inbox] ...
held={"Hello", "chat"}               -> actions=[:drain_inbox]           pending_after=nil phase=idle
```

The third line is a shape this repo's own fixtures use for `pending_user_message`
(`test/nest_web/channels/agent_channel_chat_test.exs:574`,
`test/nest_agents/agent_context_warning_test.exs:258`) and `Phase.unwrap_user/1`
accepts — but `:loop_ack` appends nothing, clears `pending_user_message` via its own
`enter/1` update, and logs nothing. `Machine.validate!` does not validate the field
(`machine.ex:285-315`), and its declared type is `term()` (`machine.ex:173`), so a future
shape fails the same silent way.

Fix: stop duplicating the shape table — normalize through `Phase.unwrap_user/1` and log
loudly when it cannot (project rule: "if something noteworthy and bad happens … the
program *should* log a warning or error"), e.g.

```elixir
defp held_user(%{pending_user_message: nil}), do: nil

defp held_user(%{pending_user_message: entry}) do
  case Phase.unwrap_user(entry) do
    {:user, %User{} = user} -> user
    _ -> nil
  end
rescue
  FunctionClauseError ->
    Logger.warning("… unrecognized pending_user_message: #{inspect(entry)}")
    nil
end
```
(or at minimum add the `{content, mode}` clause + the warning clause). This is the same
class of bug as review-c's F2: the fix is right for the two production shapes
(`{:user_message, {:user, _}}` from `deliver_inbox`, `{:user_message, %User{}}` from
`ChatPipeline`), but the "unknown → nothing held" default hides a real drop rather than
surfacing it.

## D1-4 — should-fix (UI transparency): a parked message is in **no** wire payload

`lib/nest/agents/agent/turn/executor.ex:312-315` (the drain clears the inbox and
broadcasts `[]`), `lib/nest/agents/agent/machine/transitions.ex:432-437` (the parked entry
goes to `pending_user_message` and nowhere else),
`lib/nest/agents/agent/introspection_handler.ex:272-273` (`pending_messages` /
`pending_message_count` read only `state.live.inbox`).

The D1 acceptance case "the delivered message does not fit → park it and compact first" is
pinned by `test/nest/agents/agent/machine_boundary_delivery_test.exs:115-149`, which
asserts the entries are **neither appended nor restored** — i.e. they exist only on the
machine. Since the executor already emptied and rebroadcast the inbox, the wire sequence a
human sees for their queued message is:

1. `chat:inbox` `{count: 1, messages: [<the human's message>]}` (queued),
2. `chat:inbox` `{count: 0, messages: []}` (drained) — with **no** `chat:message`, and
3. nothing at all until the compaction commits and `resume_with_pending/1` appends it.

So for the whole compaction (a full LLM request, seconds) the message is gone from the
inbox panel (count 0, no entry), absent from the transcript, and not counted by
`pendingMessageCount`; per the design note the D2 half retracts the optimistic row when
the user-sourced entry appears in `chat:inbox`, so nothing is left on screen either. That
is the "don't quietly hide data" rule inverted: a human's message becomes invisible with no
indicator. (For the *idle* chat path this is benign — the optimistic bubble survives,
because the idle path never enqueues; the invisibility is new for the queued path.)

Fix options: include the parked entry in the inbox payload (`pending_messages:
Inbox.serialize(parked ++ state.live.inbox)`) or in the status payload, or drain with
peek-then-consume (consume only after `start_chat` commits to a path). The current
`ChatPipeline.pending_user_message_struct/1` looks like it was meant for this and is dead
(see D1-9).

## D1-5 — nit: `:loop_ack` appends the held message but starts no turn ("delivers it" overstates)

`lib/nest/agents/agent/machine/transitions.ex:91-105`

With an empty inbox the emitted actions are `[{:append, {:user, user}}, {:drain_inbox}]`
and the drain is a no-op (`executor.ex:307-308`), so the machine ends `:idle` with the
human's message appended and **no turn dispatched** (probe B confirms: `pending_after=nil`,
`phase=idle`, one `:append` + `:drain_inbox`). The message is answered only when the human
next sends something (the live bridge then appends the new message after an ack). The
comment "the operator's acknowledgement delivers it instead of dropping it" and the
design note's "a refused append surfaces as a turn failure rather than a silent loss" read
as if a turn were started. Suggest one clause ("appended to the transcript; it is answered
by the next turn") rather than a code change — dispatching a turn here would re-enter the
compaction decision that just gave up.

## D1-6 — nit: the mode applied at drain time is never broadcast, so `currentMode` goes stale

`lib/nest/agents/agent/turn/executor.ex:379-397` writes `state.live.mode`; the drain's only
broadcast is `Broadcasts.inbox/2` (`executor.ex:314`). `Broadcasts.status/1` is the only
carrier of `currentMode` (`broadcasts.ex:330`, consumed at `agent_channel.ex:281` and by
the join payload), and it fires only when `Machine.status_for/1` *changes*
(`turn.ex:64`). At the `:generating` boundary the phase deliberately does not change, and
the delivered turn's own transitions (`start_chat` → `:append` → `:iterate`) do not
broadcast a status, so the UI's mode selector keeps showing the old mode until the turn
ends (or until a `tool_results` status broadcast, if the delivered turn calls a tool).
The delivered message itself carries `[mode: plan]` (`Dispatch.build_user_message/2`), so
the transcript is right and only the selector lags. Note for whoever fixes it: an extra
`{:broadcast, :status, nil}` would append a duplicate status to the sequence and break the
acceptance test's exact `["streaming","executing_tools","streaming","idle"]` assertion
(`turn_acceptance_test.exs:448`), so this needs a distinct signal or a test update.

## D1-7 — nit: `serialize/1` and `label/1` pass unvalidated types to the wire/prompt

`lib/nest/agents/agent/inbox.ex:180-192`, `:219-223`

* `mode` comes from `Map.get(payload, "mode")` with no guard; `drain_mode/1` ignores a
  non-binary (`inbox.ex:165-171`) but `serialize/1` emits it verbatim, so the browser gets
  `"mode": 123` (or a map) where the contract is a string or `null`. Probe:
  `Inbox.serialize([… mode: 123])` → `"mode" => 123`. A type guard at the channel
  (D1-1's fix) or `mode: if(is_binary(mode), do: mode)` in `put_entry/5` closes it.
* `label/1` handles `from: nil` but not `""`, so the moduledoc's claim ("an unknown sender
  (`nil`) drops the quoted name rather than putting `nil`/`""` in the prompt") is only
  half true: probe D → `"[Message from the user \"\"]\nx"`. Unreachable with the channel's
  username (validated on account creation), so this is a doc wording nit, not a bug.

## D1-8 — nit: a broken-status chat cast is dropped with no log, including from non-channel callers

`lib/nest/agents/agent/callbacks.ex:79-80` (`true -> {:noreply, state}`)

The comment justifies the silence with "the channel has already reported
`agent_status_<status>`", which is true for the channel. But `Agents.chat/4` is public and
has two non-channel callers (`lib/nest/agents/agent/sub_agent.ex:118` — a child's initial
`query`; `lib/nest/agents/agent/tool_loop.ex:381` — `agents-query`), and D1 changed the
disposition for three statuses that used to run the pipeline (`:compaction_failed`,
`:context_overflow`, `:compaction_loop_detected` ran `ChatPipeline.handle_chat/3` before,
which surfaced a visible `chat:error`/overflow broadcast; they are now silent no-ops).
For those callers the message vanishes with no signal anywhere — worth one
`Logger.warning("[agent:#{state.name}] dropping a chat message while status=#{status}")`,
which is also the honest counterpart to the "never silently drop" rule the rest of D1
follows. (The disposition itself is right; only the silence is questionable.)

## D1-9 — nit: `ChatPipeline.pending_user_message_struct/1` is dead and misses the drain shape

`lib/nest/agents/agent/chat_pipeline.ex:41-48`. No caller anywhere in `lib/` or `test/`
(grep for the name). It also handles only `{:user_message, %User{}}` and `{:user, %User{}}`
— **not** the `{:user_message, {:user, %User{}}}` shape the drain path parks
(`transitions.ex:419-421` + `dispatch.ex:100-110`), so wiring it up for D1-4's parked
message would return `nil` and reintroduce the invisibility. Either delete it or make it
`Phase.unwrap_user/1`-based and use it for the parked-message payload.

## D1-10 — nit: review-c's F4 is only half closed — 10 × 2000 ms and 2 × 750 ms fences remain in the same file

`test/nest/agents/agent/turn_acceptance_test.exs:92,137,176,294,308,359,381,387,657,660`
(2000 ms) and `:257,259` (750 ms). The two *shared* helpers did come down to 500 ms
(`test/support/agent_turn_test_helpers.ex:12,37,46`), which is the part F4 named, and the
author documents leaving the direct ones. Per `SMELLS.md:41-47` a >500 ms fence needs
measured numbers, so if F4 is accepted as a finding it is not fully resolved. Not a
regression (nothing was increased); flagging for the lead's triage only.

## D1-11 — nit: the 5 s stub valve in test 1.1.10

`test/nest/agents/agent/turn_acceptance_test.exs:548-552`
(`receive do :release_tools -> :ok after 5_000 -> :ok end`, `:546-552`). It is a safety valve inside a
stub, not a test fence, and the release is deterministic (`send(worker, :release_tools)`
after a 500 ms `assert_receive`), so it does not violate the fence rule as written — but a
failing test leaves the agent's tool worker parked for up to 5 s while the test tears down
(`stop_test_agents/0` waits 5 s per pid too), so a broken test can take ~10 s. Worth a
comment stating that it exists only so a failure cannot wedge the worker forever, or
lowering it to ~1 s.

---

## Test quality (item 5 of the brief)

Checked `test/nest/agents/agent/inbox_test.exs` (457 lines, was 165),
`test/nest/agents/agent/turn/executor_test.exs`, the two new acceptance tests,
`test/nest_web/channels/agent_channel_chat_test.exs` (699/700 — at the cap),
`test/nest_web/channels/agent_channel_queued_message_test.exs` (new, 101 lines, one merged
test — correct per "merge tests with same setup"), `test/support/agent_turn_test_helpers.ex`
(new, 66 lines, justified: it is the extraction that keeps `turn_acceptance_test.exs` at
674/700; the moduledoc is accurate and it reuses
`AgentTestAssertions.text_from_parts/1`), and `test/support/agent_test_helpers.ex`
(+`multi_mode_vocation_id_for_test/0`, needed to request a mode the agent is not in).

* **No `Process.sleep`, no `async: false`, no `:timer.sleep`** in any changed test file
  (grep). All new fences are 500 ms or 50 ms (`refute_receive`); `Eventually.eventually`
  timeouts are 500 ms.
* **Real tests**: the busy-queue path is pinned end to end (negative control in the task
  report: with the busy branch reverted to the old drop, 1.1.10 fails on
  `{:chat_inbox, %{count: 1}}`); the channel test's `assert_reply ref, :ok, %{}` cannot
  pass with the old `agent_busy` reply; `serialize/1`/`drain_mode/1` are new functions, so
  their tables pin new behaviour; the `machine_boundary_delivery_test.exs` loop-ack test
  fails with the clause reverted (author's negative control).
* **No single-assertion tests** among the new ones (the smallest is the
  `combine_and_offload` table, one behavioural claim); no duplicated setups; no assertion
  was deleted — the helper block moved out of `turn_acceptance_test.exs` verbatim, and the
  rewritten `:compacting` channel test kept its preconditions (status + inbox assertions)
  while changing the expected disposition.
* **No console output** in the focused runs (the logs above are the complete output).
* The `drain_mode`/`applied_mode` cases are genuinely table-driven: the last case
  (`mode: "bogus"` → `chat`) is the deviation-6 fallback and would fail if the executor
  stored the raw request (it now resolves through `ChatPipeline.resolve_mode_and_caps/4`).

## Project rules (item 6)

* `mix credo` clean (4046 mods/funs); `mix compile --force --warnings-as-errors` clean.
* File caps: `machine/boundary.ex` 75 total / 57 code (new); `transitions.ex` **662 total**
  (cap 700) — the extraction gave back ~24 lines, so the F12 headroom warning is milder but
  still real (~38 lines). `inbox.ex` 248, `agent_channel.ex` 675 (cap 700 — 25 lines left,
  worth knowing before adding D1-1's fallback clause). No config/lint bypasses anywhere in
  the diff (no `.credo.exs`/`.formatter.exs`/config edits).
* OTP/registry: no new raw-pid sends; `chat_or_queue` runs in the agent process (a
  `handle_cast`, not a `send`); `Inbox.busy_status?/1` is a shared definition, not useless
  delegation; `Machine.Boundary` owns exactly one pure decision and nothing else, so it is
  not a "helper that just calls another function".
* UI transparency: D1-4 and D1-6 above are the two places where D1 hides state from the
  operator; everything else in the diff is additive on the wire (the `kind`/`mode` keys are
  additive to `chat:inbox`, and `IntrospectionHandler.pending_messages` picks them up for
  free).
* SMELLS: nothing else — no redundant code (the two `{:inbox_drain, …}` clauses now share
  `deliver_inbox/3`), no useless precondition checks, no timeouts increased, no temp-file
  or `rm -rf` issues (the new test writes only under the agent's `tmp_path`).

---

## Attacks that held (what I tried to break, and why it survived)

1. **The `:loop_ack` append, for every production shape.** Correct and wire-legal. The two
   reachable shapes are exactly the two clauses (verified against the only writers of the
   field: `start_chat`'s `:needs_compaction` branch with `{:user_message, {:user, _}}` from
   `deliver_inbox/3`, and `ChatPipeline.handle_chat/3`'s `{:chat_request, {:user_message,
   %User{}}}`; every other `Compaction.stage/3` caller passes `nil` for `pending_user`). At
   `:idle` the append takes the *terminal* repair path (`MessageAppender.live_turn?/1` is
   false for `:idle`), so a tool-result or wire-`user` tail is healed by
   `MessageList.pairing_bridge/2` before the message lands and an assistant tail is legal;
   a refusal returns `{:follow, {:append_result, :invalid, _}}` which **halts** the action
   list (so the drain does not run) and hits
   `do_step(%{phase: :idle} = m, {:append_result, :invalid, reason})` →
   `fail_turn/3` → `Logger.error` + `Broadcasts.error` (`transitions.ex:239-241`) — the
   comment's claim is accurate.
2. **Double-append / re-compaction.** Held. `enter/1` clears `pending_user_message` in the
   same machine update that emits the append, and the parked entry is never in the
   transcript at that point (`:needs_compaction` does not append; `resume_with_pending/1`
   appends and clears in the same update; the `:compaction` branch is classified before
   `:empty_assistant`/`:truncated`/`:silent` in
   `Machine.Turn.classify_response/1`, so a compaction turn always commits and never
   resumes through a path that leaves the field set). A following `{:drain_inbox}` with new
   entries goes through `start_chat` → `:fits` → append + `:iterate`, and `loop_count` was
   just reset, so no re-compaction of the same message.
3. **The drained append being refused (message lost).** I could not construct it, agreeing
   with review-c's attack 2: `PreFlight.check_passed/2` fails only on `:cannot_compact`,
   which `:fits` (computed on the same reserve by `Dispatch.preflight_decision/2`)
   precludes (`system_alone_exceeds?` is false because the projection includes the system;
   `compaction_no_op?` needs an empty head, impossible after `:fits` on a transcript with a
   non-empty head). The ack-before-user ordering cannot overflow either, for the same
   reason. `:cannot_compact` restores the entries with `{:restore_inbox, entries}`.
4. **The mode changing under an *ongoing* turn.** Held. Every `{:drain_inbox}` emit site
   (`grep -rn drain_inbox lib/` → 18 hits across `Compaction`, `Response` and
   `Transitions`; `transitions.ex:103/104` are the two arms of one `case`) is either
   turn-terminal (`finalize`/`finalize_or_defer`, `llm_error`, `fail_turn`, `:stopping`) or
   enters `:idle`, except `transitions.ex:504` — the design's
   boundary, where nothing is in flight by construction. The executor applies the mode
   inside the drain action and `run_all/2` halts on its follow event, so no action of the
   ongoing turn can observe the new mode; `Turn.prepare/1` rebuilds `ctx.mode`/`ctx.caps`
   from `state.live.mode` before the *next* step, which is the delivered turn.
5. **Mode resolution.** `applied_mode/2` resolves through the same
   `ChatPipeline.resolve_mode_and_caps/4` the idle path uses, so `state.live.mode` is
   always in `Vocations.list_modes/1` ∪ `{"chat"}` (`default_mode/1` returns a real key or
   `"chat"`, and `get_caps(_, "chat")` always resolves), `nil` from `drain_mode/1` leaves
   the mode alone, and `ctx.mode`/`metadata.mode`/the `[mode: …]` prefix all agree because
   they come from the same rebuilt ctx. The `"bogus"` case is pinned at both levels.
6. **Channel disposition vs agent disposition.** `Machine.status_for/1` returns only
   `{:idle, :streaming, :executing_tools, :compacting} ∪ blocked_phases()`
   (`machine.ex:204-211`), and `Agents.get_info` reads the same function
   (`introspection_handler.ex:224`), so `@broken_statuses = Machine.blocked_phases()` is
   *exactly* the set `chat_or_queue/4` drops for — nothing falls through the channel's
   `{:ok, _}` clause into the agent's silent drop. `:stopping` maps to `:streaming`
   (chat) or `:compacting` (compaction), both busy, so a message during a stop queues and
   is delivered by the stop path's `{:drain_inbox}`. The check-and-enqueue is atomic
   (single `handle_cast` in the agent process); the channel's read is a benign TOCTOU
   because both dispositions are handled.
7. **The wire contract.** `serialize/1` emits exactly the five keys with `content`
   verbatim (no mode prefix — `put_entry/5` stores the raw text; the prefix is added by
   `Dispatch.build_user_message/2` at delivery), `"kind"` as a string, and `nil` for
   `from`/`mode` where they are absent. `combine/1`'s labels never contain `nil` (probe:
   `[Message from the user]`, `[Message from agent]`). The `@max_inbox_size` bypass is the
   only honest gap (D1-2). I found no Elixir-side mismatch with the D2 contract described in
   the design note; the JS side is the other reviewer's.
8. **Tests.** See the test-quality section: no sleeps, no `async: false`, ≤500 ms fences in
   everything D1 added, no deleted/skipped assertions, and each new behaviour has a
   negative control (the author's, plus my probe B which is itself the counterexample for
   D1-3).
