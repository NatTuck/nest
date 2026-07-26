# Stopping the parent also stops all descendant agents

## Goal

When the user clicks **Stop** on a parent's chat, every child (and grandchild,
recursively) the parent has spawned via `clone_agent` must be stopped as well.
The recursion comes for free via the existing `ChildRegistry` →
`cascade_terminate` chain — we just need to *trigger* it on chat-stop instead
of only on GenServer termination.

## Current behavior (the gap)

Today:

1. User clicks Stop → channel pushes `chat:stop` → parent GenServer.
2. `StopHandler.stop_chat_requested/2` sends `{:stop_chat, from}` to
   `chat_turn_pid`, sets `cancelled = true`.
3. `ChatTurn.Lifecycle.stop_chat/2` does
   `Process.exit(state.active_worker, :kill)` (kills the tool-worker Task),
   then sends `{:chat_stopped, self()}` to the parent and stops the ChatTurn.
4. `ChatTurnHandler.chat_stopped/1` finalizes the partial and transitions to
   `:idle`.
5. **Nothing iterates `state.chat_state.pending_children`.** The spawned child
   agent keeps running, eventually casts `:child_completed`, and the parent
   merges its usage into `descendant_usage` and `send`s `:clone_agent_result`
   to the dead `task_pid` (no-op).

`Agent.terminate/2` does walk `pending_children` (via
`SubAgent.cascade_terminate/1` → `Supervisor.cascade_children_only/1` →
`Supervisor.stop_agent/1`), but `terminate/2` only fires when the GenServer
itself dies — it does not fire on a chat stop.

The `ToolLoop.run_clone_agent/2` `receive` block matches only
`:clone_agent_result`; it has no clause for `{:stop_chat, _}`. That's fine: the
tool worker is killed before it would matter. The fix is on the Agent side.

## Design

### Where to put the cascade

`ChatTurnHandler.chat_stopped/1` is the right insertion point. By the time it
runs:

- The ChatTurn has stopped (`Lifecycle.stop_chat/2` already returned
  `{:stop, :normal, _}`).
- The active worker (tool worker Task) has been killed, so there are no
  in-flight tool workers that could race a `:clone_agent_result` send.
- `state.chat_state.pending_children` still contains the unconsumed
  `{child_name, task_pid}` entries (those were never cleared because the worker
  died before `handle_child_completed` could run).
- The parent is about to transition to `:idle` and broadcast the new status —
  children stopping is part of "the chat is done."

We do this **before** `finalize_partial_if_any` so the side-effect ordering in
the user-visible timeline is "stop requested → children stopped → chat turn
unwinds → partial finalized → status goes idle."

### What to call

`Nest.Agents.Supervisor.stop_agent/1`. It already does:

```elixir
def stop_agent(name) do
  for child_name <- ChildRegistry.children_of(name), do: _ = stop_agent(child_name)
  stop_one(name)
end
```

That recursive walk gives us the cascade for free: each child's `terminate/2`
also calls `SubAgent.cascade_terminate/1`, which calls
`Supervisor.cascade_children_only/1`, which recursively stops grandchildren.
`ChildRegistry`'s `:DOWN` self-cleanup makes the bookkeeping robust against
re-entry or a child that died between iteration steps.

`stop_agent/1` returns `:ok` on success and `{:error, :not_found}` when the
name has already been terminated (e.g. it finished just before we got here).
We treat both as success — the goal is "no descendants are running," and a
`not_found` already satisfies that. We log only the unexpected error reasons.

### Why not `stop_chat_requested/2` instead?

We could trigger the cascade earlier, in `StopHandler.stop_chat_requested/2`.
Two reasons against:

- `stop_chat_requested/2` runs *before* the ChatTurn has unwound. The active
  worker is still alive at that point; if it is in the middle of executing a
  regular (non-`clone_agent`) tool, killing children has no race but the
  messaging order is messier ("Stop arrived → children killed → tool worker
  killed → chat_turn stopped → partial finalized").
- `chat_stopped/1` is the natural "end of turn" point. It already owns
  partial finalization and the `:idle` transition. Adding one more cleanup
  step there keeps the lifecycle reasoning in one place.

### Race analysis

| Event order | Outcome |
|---|---|
| Stop arrives → child finishes → parent merges usage → we stop child | `descendant_usage` correctly reflects the child's full cost; child stops cleanly afterward. The dead `task_pid` for the tool worker means `:clone_agent_result` is a no-op send (already the current behavior for chat-stopped parents). |
| Stop arrives → we stop child → child finishes (cast in flight) | The cast lands in the parent's mailbox before `handle_cast({:child_completed, _})` runs; we then clear `pending_children` to `%{}`; `handle_child_completed` finds `nil` for `Map.get(pending_children, child_name)` and returns `{:noreply, state}` — defensive no-op. Usage is lost for that child, which matches "user asked us to stop everything." |
| Stop arrives → child already terminated (e.g. `:chat_crashed`) | `Supervisor.stop_agent/1` returns `{:error, :not_found}`. We discard it. `pending_children` already had a stale entry; clearing it is correct. |

## Implementation steps

### 1. `lib/nest/agents/agent/sub_agent.ex`

Add a new public function `stop_pending_children/1`:

```elixir
@spec stop_pending_children(Agent.t()) :: Agent.t()
def stop_pending_children(state) do
  state.chat_state.pending_children
  |> Enum.each(fn {child_name, _task_pid} ->
    _ = Supervisor.stop_agent(child_name)
  end)

  %{state | chat_state: %{state.chat_state | pending_children: %{}}}
end
```

- Clears `pending_children` in the returned state so a subsequent
  `:child_completed` cast (a child that finished just before we stopped it)
  becomes a defensive no-op in `handle_child_completed/4` (already handled —
  it `Map.get`s and short-circuits on `nil`).
- Best-effort via the `= _` discard; `not_found` is fine, anything else
  surfaces in the test logs but doesn't crash the parent.

### 2. `lib/nest/agents/agent/handlers/chat_turn_handler.ex`

Invoke the helper at the top of `chat_stopped/1`:

```elixir
defp chat_stopped(state) do
  state = state |> SubAgent.stop_pending_children() |> finalize_partial_if_any()

  state = %{
    state
    | chat_state: %{
        state.chat_state
        | status: :idle,
          chat_turn_pid: nil,
          cancelled: false
      }
  }

  Broadcasts.status(state.name, state)
  {:noreply, state}
end
```

Add `alias Nest.Agents.Agent.SubAgent` at the top of the file (alongside the
existing `alias Nest.Agents.Agent.Broadcasts`).

## Tests

### `test/nest/agents/agent/clone_agent_chat_stop_test.exs` (new)

`use Nest.DataCase, async: false` — same constraint as the registration test
because it touches the live `ChildRegistry` and `Supervisor`.

Setup mirrors `clone_agent_registration_test.exs`: ensure `ChildRegistry` is
supervised, swap parent to `MockClient`, stub `Nest.Agents.chat/2` so children
do not actually drive an LLM cycle, register a vocation with `clone_agent` in
its tool list.

Test cases:

1. **`"stopping the parent chat terminates the spawned child"`** — start
   parent, raw `:clone_agent_request` (so the child is registered but never
   advances), then send `chat:stop` via
   `Nest.Agents.Agent.stop_chat(parent_pid, self())`. Assert
   `eventually AgentsRegistry.lookup(child_name) == {:error, :not_found}` and
   `ChildRegistry.children_of(parent_name) == []`.

2. **`"the cascade walks grandchildren"`** — start parent A; raw-spawn child B
   from A (so B is registered under A and has no chat running); raw-spawn
   child C from B (so C is registered under B and is the grandchild).
   `stop_chat` A. Assert all three are gone and both
   `ChildRegistry.children_of(A)` and `ChildRegistry.children_of(B)` are
   empty lists.

3. **`"clear_pending_children is reflected on :get_pending_children"`** —
   same setup as #1, after `chat_stopped` is processed,
   `GenServer.call(parent_pid, :get_pending_children)` returns `%{}`.

4. **`"a child that completed just before stop is still merged into
   descendant_usage"`** — direct-cast `:child_completed` with a known usage
   map into the parent (using the `SubAgent.handle_child_completed/4` path
   that the existing `sub_agent_test.exs` already covers), then `stop_chat`.
   Assert the parent's `descendant_usage` retains the merged tokens (i.e. the
   order in test #1's race window: completed-before-stop wins). This pins the
   behavior so a future refactor doesn't accidentally lose usage.

### `test/nest/agents/agent/sub_agent_test.exs` (extend)

Add a unit test for `SubAgent.stop_pending_children/1`:

- Synthesize a state with two pending children (task_pid = `self()`), call
  the helper, assert `pending_children == %{}` in the returned state and
  that `Supervisor.stop_agent/1` was attempted for both. The children don't
  actually need to be running for the bookkeeping assertion; we exercise the
  end-to-end Agent-stop path in the new test file.

## Files touched

- `lib/nest/agents/agent/sub_agent.ex` — new public function
  `stop_pending_children/1`.
- `lib/nest/agents/agent/handlers/chat_turn_handler.ex` — call it at the top
  of `chat_stopped/1`; add the alias.
- `test/nest/agents/agent/sub_agent_test.exs` — add the unit test for
  `stop_pending_children/1`.
- `test/nest/agents/agent/clone_agent_chat_stop_test.exs` — new file with
  the four E2E cases above.

## Risks and notes

- `stop_pending_children/1` is synchronous and walks the full descendant
  tree. In practice the tree is bounded by `max_depth` (default 3) and the
  `clone_agent_wait_ms` of 120s — the cascade happens in milliseconds
  because `terminate/2` runs in process and is just registry walks + a
  synchronous `GenServer.stop`. No timeout risk.
- `sub_agent.ex`'s `maybe_test_swap_to_mock/1` only runs on spawn; a child
  stopped via this path is simply `GenServer.stop`-ed by the supervisor, so
  the mock swap doesn't interfere.
- The existing `stopping the parent cascades through to the child` test in
  `clone_agent_registration_test.exs` covers `delete_agent` (GenServer
  termination). The new test covers the *chat-stop* path, which is distinct.
- `ToolLoop.run_clone_agent/2`'s `receive` block stays as-is. We don't add a
  `{:stop_chat, _}` clause there because the tool worker is killed before
  it would matter, and adding the clause would require also forwarding the
  stop to the child (which the new helper already handles at the Agent
  layer).