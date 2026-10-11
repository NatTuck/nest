defmodule Nest.Agents.Agent.Machine.Backgrounding do
  @moduledoc """
  Moving an in-flight tool batch to the background (issue #36).

  A message that arrives while a batch is executing is delivered **now**: the
  batch is moved out of `worker_ref`/`active_worker` into
  `Machine.Work.backgrounded`, its calls are answered with the synthetic
  `MessageList.backgrounded_tool_result/1` plus `MessageList.backgrounded_ack/0`,
  and the turn continues with the delivered message. The batch keeps running;
  its real result — or its worker's death — then arrives as an inbox `:notice`
  (`Nest.Agents.Agent.Turn.Backgrounded`), routed by the entry recorded here.

  The delivery itself is *not* this module's own: the synthetic result and its
  acknowledgement are this path's `pre` batch, and everything else the delivery
  needs — the context-threshold notice, the reply obligation a delivered
  `:query` incurs, the consume half of peek-then-consume, and the `:iterate` —
  is `Machine.Delivery`, shared with `Transitions.start_chat/3`. The two paths
  diverged once (this one dropped the notice and the debt); they no longer can.

  Split out of `Machine.Transitions` for the credo file cap, and pure like the
  rest of the transition table: it owns the backgrounding decision
  (`backgroundable?/1`), the machine update, and the `work.backgrounded`
  bookkeeping that both this transition and the late-result routing share.

  The entry it records is `%{ref => %{pid: pid, ids: ids}}`. The ref keys the
  batch's eventual result and the pid is what its `:DOWN` is matched on; `ids`
  are the tool calls the synthetic result answered — what the stop's
  cancellation record counts (`Machine.Stopping`) and what a *death* closes: a
  result names its own ids, while a death has only this entry to name them from.

  ## The guard (decision D3)

  Backgrounding is only correct when there is something to background: the
  transcript tail must still carry unanswered `Part.ToolUse` ids — the synthetic
  result answers *every* one of them, and a partial answer is refused later by
  `:tool_pairing` — and a worker must be live to move. The pending ids are read
  from the transcript, not from `work.preflight`: preflight is a cache that
  outlives the batch it was computed for.

  A delivery that does not meet the guard is a no-op: the entries stay queued
  and the turn boundary drains them exactly as it did before. The same is true
  of a delivery that would not fit the context: `deliver_or_decline/3` runs the
  boundary's own `Dispatch.preflight_decision/2` and declines rather than
  dispatching a message the boundary would have compacted for or blocked on.

  ## Why the phase must leave `:executing_tools`

  The actions end in `:iterate`, which `:executing_tools` ignores (it is not a
  tool-execution boundary). The transition therefore enters
  `:chat`/`:generating`/`:http` — the same shape as any other turn boundary —
  so the delivered message's request is dispatched. `Phase.enter/4` is what
  nulls `worker_ref`/`active_worker`, which is why the batch is recorded on
  `work.backgrounded` *before* it runs.

  ## What a stop does

  A stop kills every backgrounded worker and clears every entry
  (`Machine.Stopping`), so no batch keeps running past the stop and no entry
  leaks. The `:stopping` guards in `Machine.Transitions` then drop the batch's
  late result and its worker's `:DOWN`: the stop path has already recorded the
  cancellation (`Turn.Backgrounded.cancellation/1`), so delivering the batch's
  own outcome as well would report the same call twice.
  """

  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Delivery
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.MessageList

  @doc """
  Whether the in-flight batch can be moved to the background for a queued
  message to be delivered now.

  Total on any machine, including a hand-built fixture with no context: a
  machine with nothing in flight is simply not backgroundable.

  The structural half of the decision only — a live worker and something left
  to answer. Whether the *delivery* fits the context is `step/3`'s own check,
  because it needs the message.
  """
  @spec backgroundable?(Machine.t()) :: boolean()
  def backgroundable?(%Machine{phase: :executing_tools, work: work}) do
    is_reference(work.worker_ref) and is_pid(work.active_worker) and
      pending_tool_uses(work.ctx) != []
  end

  def backgroundable?(_machine), do: false

  @doc """
  The transition: background the batch and continue the turn with the
  delivered message. The no-op shapes — nothing in flight, or a delivery that
  would not fit — leave the entries queued.
  """
  @spec step(Machine.t(), [term()], String.t()) ::
          {:ok, [term()], Machine.t()} | {:ignore, atom(), Machine.t()}
  def step(m, entries, content) do
    if backgroundable?(m) do
      deliver_or_decline(m, entries, content)
    else
      {:ignore, :no_batch_to_background, m}
    end
  end

  @doc """
  Every `work.backgrounded` ref owned by `pid`, **sorted** so the notices it
  produces are deterministic (the map is keyed by ref, so iteration order is
  arbitrary and two notices from one dead pid would otherwise enqueue in a
  different order on every run). Keyed by value, so it is a linear scan —
  batches are few, so that is fine. Two entries can share a pid, so the caller
  must resolve *all* of them: resolving only the first would leak the rest
  forever.
  """
  @spec refs_for(Machine.t(), pid()) :: [reference()]
  def refs_for(m, pid) do
    m.work.backgrounded
    |> Enum.filter(fn {_ref, %{pid: owner}} -> owner == pid end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  The tool-call ids the backgrounded batch `ref` answered — how a *death* names
  the promises it closes.

  A result names its own ids (`fulfilled_ids/1`); a worker that dies delivers
  none, so the ids come from the entry the batch was recorded in. Total: an
  unknown ref names nothing.
  """
  @spec ids_for(Machine.t(), reference()) :: [String.t()]
  def ids_for(m, ref) do
    case m.work.backgrounded do
      %{^ref => %{ids: ids}} -> ids
      _ -> []
    end
  end

  @doc """
  The tool-call ids a backgrounded batch's *result* answers.

  The delivery's notice carries them onto the message the drain appends
  (`Inbox.deliver_notice/3` → `Inbox.build_drained_message/3`), so a later load
  can tell a promise that was kept from one the process died with
  (`MessageList.backgrounded_results/1`).

  Total over any result list: anything that is not a tool result answers no
  call.
  """
  @spec fulfilled_ids([term()]) :: [String.t()]
  def fulfilled_ids(results), do: for(%{tool_call_id: id} <- results, do: id)

  @doc "Drop backgrounded entries, so each ref can be delivered exactly once."
  @spec clear(Machine.t(), [reference()]) :: Machine.t()
  def clear(m, refs) do
    %{m | work: %{m.work | backgrounded: Map.drop(m.work.backgrounded, refs)}}
  end

  @doc """
  How many tool calls the backgrounded batches answered — the count the Stop's
  cancellation record reports (`Machine.Stopping`).

  A batch is *one* entry however many calls it carried, so `map_size/1` would
  announce a three-call batch as one call; each entry's own ids are the calls
  the synthetic result answered, and the record's promise is about the calls,
  not the entries.
  """
  @spec call_count(Machine.t()) :: non_neg_integer()
  def call_count(m) do
    m.work.backgrounded
    |> Enum.map(fn {_ref, %{ids: ids}} -> length(ids) end)
    |> Enum.sum()
  end

  @doc """
  The `{:kill, pid}` actions that stop every backgrounded batch (the Stop
  transition's half of the kill list).

  **Sorted** — the map's iteration order is arbitrary, so the action list would
  otherwise differ from run to run — and **distinct**, because two entries can
  share a pid (the same batch backgrounded under two refs) where one kill is
  enough. Every kill routes through the executor's `{:kill, pid}`, whose
  `{:stop_chat, self()}` handshake is what lets a `shell-cmd` worker clean up
  its `bwrap` OS process before it goes.
  """
  @spec kill_actions(Machine.t()) :: [{:kill, pid()}]
  def kill_actions(m) do
    m.work.backgrounded
    |> Enum.map(fn {_ref, %{pid: pid}} -> pid end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{:kill, &1})
  end

  @doc """
  The actions that deliver a backgrounded batch's outcome.

  `{:deliver_backgrounded, …}` only *enqueues* the notice. When the turn that
  backgrounded the batch has already ended, the machine is `:idle` and nothing
  else would ever wake it — the notice would sit in the queue forever, and an
  `agents-wait` on the idle agent would resolve with the pre-result answer
  (breaking issue #36's headline promise and invariant 1). The `{:drain_inbox}`
  is what starts the notice's own turn, exactly as `Transitions.child_event/2`
  drains a child's answer into an idle parent. Every other phase either has a
  turn boundary of its own coming (`:generating`, `:executing_tools`) or cannot
  drain at all (a blocked phase's `{:unblocked}` does it), so the drain is
  `:idle`-only.
  """
  @spec delivery_actions(Machine.t(), [term()]) :: [term()]
  def delivery_actions(%Machine{phase: :idle}, deliveries), do: deliveries ++ [{:drain_inbox}]
  def delivery_actions(%Machine{}, deliveries), do: deliveries

  # The batch's calls, read from the transcript: the tail assistant is the one
  # that requested them, and every `Part.ToolUse` on it is unanswered by
  # construction (a result would have replaced the tail).
  defp pending_tool_uses(%{messages: messages}) when is_list(messages) do
    MessageList.unpaired_tail_tool_uses(messages)
  end

  defp pending_tool_uses(_ctx), do: []

  # The delivery's own fit check: the same `Dispatch.preflight_decision/2` the
  # turn boundary's `start_chat/3` runs on the projected list. A delivery that
  # would not fit declines to background instead, and the entries stay queued for
  # the boundary that drains them — which is where the real decision lives
  # (`:needs_compaction` stages the compaction, `:cannot_compact` blocks with the
  # overflow banner). Dispatching it from here would skip both decisions and
  # append a message the context cannot hold, with the batch's own result still
  # to come.
  defp deliver_or_decline(m, entries, content) do
    # The delivered message in the batch's own mode, built by the same
    # `Inbox.build_drained_message/3` every other drain shape uses. The
    # executor's peek has already applied the mode to `state.live.mode`, and
    # `Turn.prepare/1` rebuilt the context from it, so `ctx.mode` is the winning
    # mode — and the builder is what carries a drained batch's `fulfilled_ids`
    # onto the message, so a notice delivered *here* marks its promise kept
    # exactly as one drained at the turn boundary does.
    user = Inbox.build_drained_message(entries, content, m.work.ctx.mode)

    if fits?(m, user) do
      background(m, entries, user)
    else
      {:ignore, :delivery_would_not_fit, m}
    end
  end

  defp fits?(m, user) do
    Dispatch.preflight_decision(Delivery.projected(m, [], user), m.work.ctx.context_limit) ==
      :fits
  end

  defp background(m, entries, user) do
    calls = pending_tool_uses(m.work.ctx)
    {:tool, _} = synthetic = MessageList.backgrounded_tool_result(calls)

    # The delivery itself is shared with the turn boundary (`Machine.Delivery`):
    # the synthetic result and its acknowledgement are this path's own `pre`
    # batch, and the notice, the reply debt, the consume and the `:iterate` are
    # the same ones `start_chat/3` assembles. The synthetic result answers the
    # batch's calls, which is what lets the notice pair land (see the module
    # doc of `Machine.Delivery`).
    {actions, m} = Delivery.fits(m, [synthetic, MessageList.backgrounded_ack()], entries, user)

    machine =
      m
      |> put_backgrounded(m.work.worker_ref, %{
        pid: m.work.active_worker,
        ids: Enum.map(calls, & &1.id)
      })
      |> Phase.enter(:chat, :generating, :http)

    {:ok, actions, machine}
  end

  defp put_backgrounded(m, ref, batch) do
    %{m | work: %{m.work | backgrounded: Map.put(m.work.backgrounded, ref, batch)}}
  end
end
