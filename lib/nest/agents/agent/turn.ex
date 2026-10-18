defmodule Nest.Agents.Agent.Turn do
  @moduledoc """
  The Agent's settle loop: the one runtime driver of the pure machine.

  `settle/2` translates a real-world event into a `Machine.step/2` call,
  commits the next machine, broadcasts a status change, runs the returned
  actions through `Turn.Executor`, and recurses on any follow-up event the
  executor produced. Every turn decision lives in `Machine.step/2`; every
  effect lives in `Turn.Executor`.

  Lifecycle and worker messages are translated here (`handle/2`) and by
  `Nest.Agents.Agent.Handlers` / `Callbacks`. LLM streaming deltas remain
  in `Handlers.LLMStreamHandler` because they touch only the in-flight
  accumulator, never the machine.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.Timeline
  alias Nest.Agents.Agent.Turn.Executor
  alias Nest.Sandbox.Mounts

  @max_settle_depth 200

  @doc """
  Settle `event` against `state`. Returns `{:ok, state}`.
  """
  @spec settle(Agent.t(), term()) :: {:ok, Agent.t()}
  def settle(state, event), do: settle(state, event, 0)

  defp settle(_state, _event, depth) when depth > @max_settle_depth do
    raise "Turn.settle exceeded #{@max_settle_depth} recursions; a transition is cycling"
  end

  defp settle(state, event, depth) do
    state = prepare(state)
    machine = state.live.machine
    old_status = Machine.status_for(machine)
    # The indices a turn appends are stamped by the executor, so they are only
    # knowable after the actions have run; the snapshot is the other half of
    # that diff (`Timeline.added/2`).
    before = Timeline.snapshot(state)

    case Machine.step(machine, event) do
      :quarantine ->
        {:ok, quarantine!(state, event)}

      {:ok, actions, next} ->
        Timeline.tools(state, event, machine)
        run(state, old_status, next, actions, depth, {machine, event, before})

      {:ignore, _reason, next} ->
        run(state, old_status, next, [], depth, {machine, event, before})
    end
  end

  defp run(state, old_status, next, actions, depth, trace) do
    state = put_machine(state, next)

    # The mode a drain's peek may apply, and the queue it is compared against,
    # so an attempt that consumed nothing can be undone
    # (`restore_undelivered_mode/3`).
    #
    # `pre_inbox` is the queue *before* this action list ran, not the queue the
    # peek saw: an action earlier in the list can enqueue before a later
    # `{:drain_inbox}` runs (`{:deliver_backgrounded, …}`'s notice and
    # `{:child_message, …}`'s delivery both do), so the peek can see a longer
    # queue. `restore_undelivered_mode/3` states the invariant under which the
    # two agree wherever the decision reads them.
    pre_mode = state.live.mode
    pre_inbox = state.live.inbox

    # Effects land before the status change is announced, matching the old
    # driver (append the message, then broadcast idle/streaming). A status
    # broadcast that preceded the append would let a subscriber observe the
    # new status before the message that motivated it.
    {state, follow} = Executor.run_all(actions, state)

    # The transition is recorded before the broadcast it causes: a subscriber
    # woken by the status frame must not find the timeline still missing the
    # transition behind it.
    {machine, event, before} = trace
    Timeline.turn(state, event, machine, next, Timeline.added(before, state))
    Timeline.debt_changes(state, machine, next)

    if Machine.status_for(state.live.machine) != old_status, do: Broadcasts.status(state)

    state =
      case follow do
        nil ->
          restore_undelivered_mode(state, pre_mode, pre_inbox)

        event ->
          {:ok, settled} = settle(state, event, depth + 1)
          restore_undelivered_mode(settled, pre_mode, pre_inbox)
      end

    {:ok, keep_mode(state, pre_mode)}
  end

  @doc """
  Tell every tool worker this turn is running to stop its command and report a
  tool error, because the space's environment changed under it.

  The pids are the machine's: the active worker and any batch it moved to the
  background. A worker that is not running a command — the http worker, a batch
  between calls — does not consume the message where it stands: `ShellCmd`
  discards a leftover one before its next command starts
  (`flush_cancel_tool/0`), so the message stops the command that was running when
  the edit began and never one that began after it.

  A batch's context is a **snapshot** (`Turn.build_ctx/2` captures `mounts:` and
  `caps:`, and `ToolLoop.execute/3` never re-reads the state), so cancelling here
  does not move a batch already in flight onto the new environment: the call it
  has running is stopped and the agent is told, and the calls it has left still
  run against the mounts it was built with. Only a batch that *starts* after the
  write — every later turn — runs under the new values. Cancelling every in-flight
  batch as well is a follow-up, not something this function can do.

  Only a *long* tool can be cancelled, because only it owns an OS process to
  stop — `Nest.Tools.ShellCmd.collect_output/5` is the one clause that matches the
  message. A short tool waits at the gate instead, which is why it needs no
  clause here and burns no retry; `Nest.Agents.SpaceGate`'s moduledoc states the
  rule.
  """
  @spec cancel_tools(Agent.t(), String.t()) :: :ok
  def cancel_tools(state, reason) do
    work = state.live.machine.work

    [work.active_worker | Enum.map(Map.values(work.backgrounded), & &1.pid)]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&send(&1, {:cancel_tool, reason}))

    :ok
  end

  @doc """
  Write down a mode change the turn **kept**.

  The row is written here, not where the mode is applied, and that is what keeps
  an undone change out of it: `restore_undelivered_mode/3` runs first, so
  reaching here with a different mode means the message that asked for it was
  delivered. The row is the truth a restart and a later spawn read
  (`Nest.Agents.Agent.PreSpawn`), so it must hold exactly what the agent is
  actually working under.

  It is `state.live.mode` that is written — the *resolved* mode — rather than the
  name an entry carried: a request this build does not implement is resolved
  (`Nest.Modes`) before it is applied, and the row must not keep the stale name.

  The callers are every place a kept change can be observed: `run/6`, which
  covers each drain it runs *and* the one `drain_inbox/1` runs itself (the settle
  inside it reads the already applied mode, so `run/6`'s own snapshot cannot see
  that change), and `ChatPipeline.handle_chat/4`, for the human's own selection
  riding a chat message.

  Nothing is announced. Every message states the recipient's mode — a human's
  carries it as a `[mode: X]` prefix, a peer's in its header — so a change
  already arrives with the statement of itself.
  """
  @spec keep_mode(Agent.t(), String.t()) :: Agent.t()
  def keep_mode(state, pre_mode) when state.live.mode == pre_mode, do: state

  def keep_mode(state, _pre_mode) do
    Nest.Persistence.update_agent_mode(state.space_id, state.name, state.live.mode)

    state
  end

  # A drain that delivered nothing must not leave its mode applied (issue #103).
  #
  # `Executor.peek_inbox/1` applies the queued batch's mode when it peeks,
  # because the message the machine appends is built from `ctx.mode` inside the
  # transition (`Machine.Delivery.fits/4` -> `Inbox.build_drained_message/3`)
  # and because the mode frame a subscriber sees while a batch is still
  # executing is read from `state.live.mode` — both of which happen before the
  # transition's outcome is known. A drain that consumes nothing — declined
  # because the context cannot hold the message, parked on a compaction it
  # needs, blocked, or refused — therefore has to put the mode back:
  # `Turn.prepare/1` rebuilds `ctx.mode`/`ctx.caps` from `state.live.mode` on
  # every settle, so a leaked mode re-resolves the ongoing turn for a message
  # that was never delivered.
  #
  # The consume action is emitted only by the branch that appended the message
  # (`Machine.Delivery.consume_actions/1`), so "the peeked batch is entirely
  # still queued" is exactly "this drain delivered nothing". A delivery that
  # consumed a strict prefix (a lone human message ahead of peer entries)
  # consumed its batch and is not undone.
  #
  # The check is `Inbox.batch/1` of `pre_inbox`, the queue *before* the action
  # list ran — not the queue the peek saw, which an earlier action in the same
  # list can have made longer (see `run/6`). The two agree wherever this
  # decision reads them, and these are the properties that make it so:
  #
  #   * an action appends its entry (`Inbox.put_entry/7` appends to the queue),
  #     so an earlier action can only ever put entries *behind* what was queued;
  #   * a batch is a head prefix of the queue — a lone human message, or the run
  #     of leading non-human entries (`Inbox.batch/1`);
  #   * the only entries an action earlier in the list adds today are mode-less
  #     ones — `{:deliver_backgrounded, …}`'s outcome and `{:child_message, …}`'s
  #     delivery both go through `Inbox.enqueue_internal/5`, which passes
  #     `mode: nil` — so they cannot change the mode a drain applies.
  #
  # An append can therefore only *extend* a batch, and a batch that applies a
  # mode is a lone human message at the head, which no append can change — so
  # whenever the mode changed, the batch the peek saw is exactly
  # `Inbox.batch(pre_inbox)`, and this check is exact in both directions. With
  # `pre_inbox == []` the `batch != []` guard skips the restore, which is
  # correct for the same reason: a queue with no `:user` entry applies no mode,
  # so the short-circuit above already returned.
  #
  # What would break it: a new action that enqueued a *mode-carrying* entry
  # before a drain in the same list (every action's enqueue goes through
  # `Inbox.enqueue_internal/5`, which passes `mode: nil`, so a mode arrives only
  # from a *delivery* — the human's chat, or a peer's `set_mode` — and never from
  # inside the list), or one that inserted at the head instead of appending. Either would make the peek's
  # batch differ from `Inbox.batch(pre_inbox)` — and the restore would then be
  # skipped with `pre_inbox == []`, or tested against entries the peek never
  # saw, leaking the applied mode. Making the check robust instead would mean
  # threading the peeked batch out of `Executor.run_all/2`, which is not worth
  # its return contract; this comment is the contract instead.
  #
  # The mode is the only thing a peek can write in `run_all`, so an unchanged
  # mode means no peek ran and there is nothing to look at.
  defp restore_undelivered_mode(state, pre_mode, _pre_inbox) when state.live.mode == pre_mode,
    do: state

  defp restore_undelivered_mode(state, pre_mode, pre_inbox) do
    batch = Inbox.batch(pre_inbox)

    if batch != [] and Enum.all?(batch, &(&1 in state.live.inbox)) do
      state = %{state | live: %{state.live | mode: pre_mode}}

      # The peek published the mode it applied; the UI must not be left showing
      # a mode that never took effect.
      Broadcasts.status(state)
      state
    else
      state
    end
  end

  # An undeclared event is drift. Log loudly, then fail the turn cleanly
  # back to idle so a stray message can never leave the agent wedged in a
  # busy phase. An already-idle agent is left untouched.
  defp quarantine!(state, event) do
    require Logger

    Logger.error("[agent:#{state.name}] quarantined undeclared turn event: #{inspect(event)}")

    # The quarantine is the one turn outcome with no `turn` event (there was no
    # transition), so the timeline's `error` type carries it.
    Timeline.error(
      state.space_id,
      state.name,
      "quarantined turn event: #{inspect(event)}",
      "Turn.quarantine!/2"
    )

    if state.live.machine.phase == :idle do
      state
    else
      error = %RuntimeError{message: "quarantined turn event: #{inspect(event)}"}

      # The turn is over, so a reply it still owes is given up with it. The
      # funnel computes that (`Phase.rest/4`), and its give-up is prepended to
      # the failure action — the executor runs the list in order, so the
      # requesters hear first and the turn fails second.
      {:ok, actions, machine} =
        Phase.rest(state.live.machine, state.live.machine.kind, :quarantine, [
          {:fail_turn, error, []}
        ])

      state = %{state | live: %{state.live | machine: machine}}
      {state, _follow} = Executor.run_all(actions, state)
      Broadcasts.status(state)
      state
    end
  end

  # --- GenServer info dispatch ---

  @doc "Translate a GenServer message into a machine event and settle it."
  @spec handle(term(), Agent.t()) :: {:noreply, Agent.t()}
  def handle(:iterate, state), do: reply(settle(state, :iterate))
  def handle(:stop_timer, state), do: reply(settle(state, :stop_timer))

  # Compatibility `send/2` path for the legacy `{:chat_stopped, _}`: force
  # the stop transition and tear down outstanding query children immediately.
  def handle({:chat_stopped, from}, state) do
    {:ok, state} = settle(state, {:stop, from})
    {:noreply, SubAgent.stop_pending_children(state)}
  end

  def handle({:http_response, ref, response}, state) when is_map(response) do
    reply(settle(state, {:http_ok, ref, response}))
  end

  def handle({:http_error, ref, reason}, state) do
    reply(settle(state, {:http_error, ref, reason}))
  end

  def handle({:worker_crashed, ref, exception, stacktrace}, state) do
    reply(settle(state, {:worker_crashed, ref, exception, stacktrace}))
  end

  def handle({:tool_results, ref, results}, state) do
    reply(settle(state, {:tool_results, ref, results}))
  end

  # A tool worker's "my `agents-send` reached its target". Sent before its
  # `{:tool_results, …}`, so the debt is discharged before the response that
  # would settle the turn (issue #31 §1.4).
  def handle({:reply_sent, sender}, state), do: reply(settle(state, {:reply_sent, sender}))

  def handle({:DOWN, _mref, :process, pid, reason}, state) do
    reply(settle(state, {:worker_down, pid, reason}) |> notice_lost_batch(pid, reason))
  end

  def handle({:llm_error, error_msg}, state) do
    ref = state.live.machine.work.worker_ref
    reply(settle(state, {:llm_error, ref, error_msg}))
  end

  # A batch coordinator that died before its aggregate is a batch that will never
  # complete: the parent is told rather than left waiting. Only the aggregate is
  # lost — a child that has not reported yet is unaffected, because with the
  # target gone its delivery falls back to this agent's inbox. (An outcome the
  # coordinator had already received dies with it; see
  # `BatchCoordinator`'s "What a killed coordinator loses".)
  #
  # A Stop never reaches here. The load-bearing reason is that the stop clears
  # the children map before the coordinators' `:DOWN`s arrive, so there is no
  # reporting target left to report; the `cancelled` check is belt-and-braces
  # insurance for the same window (it is true for the whole stop, and no
  # reachable state was found where it is the only thing preventing a notice —
  # it is kept because it says the intent outright: a stop the parent asked for
  # is not a lost batch).
  defp notice_lost_batch({:ok, state} = settled, pid, reason) do
    # `:normal` is a coordinator that finished (it delivered its aggregate on the
    # way out): nothing to report.
    if reason != :normal and not state.live.cancelled and
         Children.reporting_target?(state.live.machine.children, pid) do
      state =
        Inbox.enqueue_internal(
          state,
          "agents-batch",
          "The batch coordinator stopped before reporting its aggregate " <>
            "(#{inspect(reason)}). The answers of any children still running will " <>
            "arrive as messages instead.",
          :runtime
        )

      state =
        if Machine.status_for(state.live.machine) == :idle do
          {state, _result} = drain_inbox(state)
          state
        else
          state
        end

      {:ok, state}
    else
      settled
    end
  end

  defp reply({:ok, state}), do: {:noreply, state}

  @doc """
  Drain queued async messages through the executor (the single drain
  path). Returns `{state, :delivered | :queued}`. Used by
  `Inbox.handle_delivery/3` (idle target).

  `:delivered` means nothing this drain found queued is still queued: the
  entries it peeked were consumed and delivered to the transcript. `:queued`
  means at least one of them survived — the delivery parked on a compaction it
  needed before it could fit, or on a `:cannot_compact` block — so the message
  is still queued and visible on the wire. The reply is computed from the queue
  this drain peeked, not from "the inbox is empty": under peek-then-consume
  (#26) the executor leaves the queue alone, so a delivery that did not consume
  anything must report `:queued`.

  A drain that delivered nothing also leaves the agent's mode as it was: the
  peek applies the queued batch's mode (`Executor.peek_inbox/1`), and an
  attempt that consumed nothing undoes that application
  (`restore_undelivered_mode/3`), so a mode never sticks for a message that is
  still queued (issue #103).
  """
  @spec drain_inbox(Agent.t()) :: {Agent.t(), :delivered | :queued}
  def drain_inbox(state) do
    # The empty-inbox clause is the total-function shape for a caller that
    # drained nothing. A *non-empty* queue always peeks a non-empty batch
    # (`Inbox.batch/1` selects a head prefix, and its head always matches one
    # of its clauses), so there is always a `{:inbox_drain, …}`
    # follow event.
    case state.live.inbox do
      [] ->
        {state, :delivered}

      entries ->
        # The queue this drain peeked, and the mode before the peek may have
        # applied the batch's: both are what an attempt that delivers nothing
        # has to leave alone.
        pre_mode = state.live.mode
        {state, follow} = Executor.run_all([{:drain_inbox}], state)

        state =
          if follow do
            {:ok, settled} = settle(state, follow)
            restore_undelivered_mode(settled, pre_mode, entries)
          else
            state
          end

        # This drain is the one `run/6` cannot see: the settle above runs its own
        # `run/6`, whose `pre_mode` is read *after* the peek applied the batch's
        # mode, so its `keep_mode/2` finds nothing to do. A mode this drain kept
        # is therefore written here — and one it delivered nothing for was just
        # undone above, so there is no change left to write.
        state = keep_mode(state, pre_mode)

        delivered? = not Enum.any?(entries, &(&1 in state.live.inbox))
        {state, if(delivered?, do: :delivered, else: :queued)}
    end
  end

  # --- context preparation ---

  # The pure machine reads its world from `work.ctx`. Rebuild the volatile
  # parts from Agent state before every step so `step/2` never touches a
  # stale snapshot.
  defp prepare(state) do
    machine = state.live.machine
    work = machine.work
    ctx = build_ctx(state)

    machine = %{machine | work: %{work | ctx: ctx, max_iterations: max_iterations(work)}}
    %{state | live: %{state.live | machine: machine}}
  end

  defp max_iterations(%{max_iterations: m}) when is_integer(m) and m > 0, do: m
  defp max_iterations(_), do: Config.configured_max_tool_iterations()

  @doc """
  Build a fresh turn context. Public so callers can inspect the projected
  request without side effects.
  """
  @spec build_ctx(Agent.t(), keyword()) :: map()
  def build_ctx(state, opts \\ []) do
    mounts = Mounts.from_agent(state)
    {mode, caps} = ChatPipeline.resolve_mode_and_caps(state.live.mode, state.vocation, mounts)

    %{
      agent_pid: self(),
      agent_name: state.name,
      space_id: state.space_id,
      client_config: state.client_config,
      tools: Keyword.get(opts, :tools, state.tools),
      tool_choice: Keyword.get(opts, :tool_choice, :auto),
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      context_limit_source: state.llm_metrics.context_limit_source,
      messages: Keyword.get(opts, :messages, state.chat_state.messages),
      mounts: mounts,
      mode: mode,
      next_message_index: state.chat_state.next_message_index,
      crossed_thresholds: state.live.crossed_thresholds,
      context_projection: state.live.context_projection,
      api_log_sequences: state.live.api_log_sequences,
      # Read by `Machine.Transitions` to decide whether a queued inbox message
      # is delivered at the turn boundary (issue #15).
      inbox_count: length(state.live.inbox),
      vocation: state.vocation,
      depth: state.depth
    }
  end

  defp put_machine(state, machine), do: %{state | live: %{state.live | machine: machine}}
end
