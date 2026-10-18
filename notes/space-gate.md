# The space gate

A space's environment — its workspace, its network access and its sandbox backend
— is carried on every agent's `Nest.Sandbox.Mounts`, which is what its caps
resolve from and what its tool closures were built with. Editing it therefore
means the agents are running under values that are about to change, and the edit
has to reach them. The window between "the row is being written" and "the agents
have the new values" is what `Nest.Agents.SpaceGate` makes safe.

## The latch

`SpaceGate` is a per-space **before-starts latch**, not a lock around the write:

* while it is held, a **tool use** waits at the gate before it starts
  (`Nest.Agents.Agent.BatchSizer.execute_one/2`), and then runs with the mounts
  its **batch** was built with: a batch that starts after the write runs under
  the new values, while a batch already in flight is a snapshot taken before it
  and keeps the old ones — the edit cancels that batch where it has a long call
  running (`Turn.cancel_tools/2`) and tells the agent, but the calls it has left
  still run against what it was built with;
* an **agent start** waits too (`Nest.Agents.Supervisor.fetch_or_start_agent/2`),
  so a process cannot read the row halfway through the write;
* a **spawn** waits at its own entry point
  (`Supervisor.spawn_agent_in_space/5`, `start_agent_with_parent/4`) because those
  start a child without going through `fetch_or_start_agent/2` — and the child is
  new, so no cast and no `space_notice_pending` mark would ever reach it;
* a **turn start** does not wait, and does not run either: the message is queued
  on the agent's own inbox (`Callbacks.chat_or_queue/5`) and the unlock drains it.
  An agent process must never block on the latch — it would stop answering
  everything else — which is why this is a deferral and not a call.

Nothing is refused. A held start or tool call is a *pause*, so cancelling an edit
costs nothing: the latch is released and everything proceeds.

## Why cancellation instead of waiting

The latch deliberately **does not drain**. Work that was already running when it
went up is not waited for; the edit cancels it
(`Nest.Agents.Agent.cancel_tools/2`). That is what lets the reader side be one
`:ets.member/2` on the hot path (every tool use) with no counter to increment, no
supervisor to consult and no chance of a leaked count wedging a space.

A counting mutex would have to answer "how much work is in flight?" on every tool
call, and a count that is wrong in either direction is worse than no latch: too
high and the edit waits forever, too low and it proceeds under a running command.
Cancelling moves that problem to the one place that can solve it — the tool that
owns the process — and makes the wait unbounded-but-terminating, because the latch
always comes down (release, owner `:DOWN`, or the TTL).

The claim lives in a `:protected` ETS table owned by the gate process, so reads
are lock-free from any process; writes go through the server because a write also
arms the monitor and the timer. The wake-up rides its own PubSub topic
(`space_gate:<id>`), subscribed by the space's agents (a deferred turn waits for
it) and by the lobby channels that show the paused banner.

## What can be cancelled, and why that is a rule about time

**Only tools that take time can be cancelled**, because only they own an OS
process to stop. The cancellation is a message to the turn's worker pids
(`Turn.cancel_tools/2`), and the one clause that matches it is
`Nest.Tools.ShellCmd.collect_output/5`'s: it stops the process and returns a tool
error, so the agent can re-issue the call.

Every other tool is *short* — `file-write`, `agents-spawn`, `context-compact`,
anything answering from memory — and needs no cancellation: a short tool that
arrives while the latch is up waits at the gate and then runs against the new
values, so no retry is burned. (A cancellation that finds a worker *between* two
commands is discarded before the next one starts —
`ShellCmd.flush_cancel_tool/0` — so it cannot stop a command that began after the
edit.) This is a statement about **duration**, not a list
of exempted tools. A future tool that spawns an OS process or otherwise runs
unbounded time belongs in the cancellable set (it needs a `{:cancel_tool, …}`
clause that stops it); a future tool that merely waits for the latch does not, and
giving it a clause would report a cancellation it never had.

## The two phases

`Nest.Spaces.Environment.update_environment/3` is the space edit:

1. the first call takes the latch, reads the plan (the working agents and the
   running background jobs) and, when anything is running, answers
   `{:error, {:confirmation_required, plan}}` **without writing**;
2. the second call — the same call with `confirm: true` — quiesces (cancels the
   tool calls, stops the jobs) and writes the row.

The latch is taken **before** the plan is read, and stays up while the user
decides. That is what makes the plan exact: nothing can start in the space, so
the set it names cannot grow between the preview and the confirmation. It is also
what makes cancelling free — the user's "no" is one `release/1`
(`NestWeb.LobbyChannel`'s `cancel_edit_space`), and the space resumes.

The row is written after the quiesce and before the release, so the cancel
happens *inside* the window the latch protects. What that buys is bounded and
worth stating exactly: a batch **that starts after the write** runs under the new
values, and the long call a batch already had running is stopped. A batch already
in flight is not moved onto the new environment — its context was built from the
old mounts before the latch went up — so its remaining calls still run against
them. Making an edit cancel every in-flight batch (rather than the long call it
has running) is a follow-up; nothing today does it.

## What the user sees

The hold is announced (`{:space_locked, id}`) and the release too, on the gate's
topic; the lobby forwards both as `space:paused`/`space:resumed` to every session
that can see the space, and the join payload carries `paused_space_ids` for a
session that opens mid-pause. `SpacePausedBanner` renders it on every screen that
belongs to the space — the overview, an agent's chat, and a campaign's Main View
— because a paused space looks exactly like a stuck one otherwise, and the
transparency rule says the user must be able to see that work is held and why.

## Residuals

* **The singleton is a single point of silence.** The ETS table is owned by the
  gate process; if that process crashes, the table goes with it and `held?/1`
  answers `false` — the latch is silently down. The direction is the safe one (a
  paused space resumes rather than wedging), but it is silent, and an edit that
  was mid-flight when it happened proceeds with tools in flight. A crash mid-edit
  therefore means the edit lands with the space running.
* **`archive_space` does not share the quiesce.** It kills every process in the
  space unconditionally (`Spaces.archive_space/1` → `stop_space_agents/1`) rather
  than taking the latch and cancelling the way an environment edit does. Archiving
  is a teardown, so the outcome is defensible — but it means there are two ways a
  space's work stops, with different manners, and the gate is only on one of them.
* **A cancelled tool is not retried for the agent.** The agent gets a tool error
  saying the environment changed and may re-issue the call; nothing re-issues it
  automatically. That is deliberate (the model decides what is still worth doing
  under the new values), but it does mean an edit costs the in-flight calls.
