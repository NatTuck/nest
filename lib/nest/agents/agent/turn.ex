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

    case follow do
      nil -> {:ok, state}
      event -> settle(state, event, depth + 1)
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
          :notice
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
  entries it peeked were consumed, so the batch reached the transcript.
  `:queued` means at least one of them survived — the delivery parked on a
  compaction it needed before it could fit, or on a `:cannot_compact` block —
  so the message is still queued and visible on the wire. The reply is
  computed from the queue this drain peeked, not from "the inbox is empty":
  under peek-then-consume (#26) the executor leaves the queue alone, so a
  delivery that did not consume anything must report `:queued`.
  """
  @spec drain_inbox(Agent.t()) :: {Agent.t(), :delivered | :queued}
  def drain_inbox(state) do
    # The empty-inbox clause and the `nil` follow-event clause below are
    # unreachable from the only caller (`handle_delivery/3` enqueues first, and
    # a non-empty queue always yields the `{:inbox_drain, …}` follow event).
    # They are kept as the total-function shape, not as a contract.
    case state.live.inbox do
      [] ->
        {state, :delivered}

      entries ->
        {state, follow} = Executor.run_all([{:drain_inbox}], state)

        case follow do
          nil ->
            {state, :delivered}

          event ->
            {:ok, state} = settle(state, event)
            delivered? = not Enum.any?(entries, &(&1 in state.live.inbox))
            {state, if(delivered?, do: :delivered, else: :queued)}
        end
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
    {mode, caps} =
      ChatPipeline.resolve_mode_and_caps(
        state.live.mode,
        state.vocation,
        state.workspace_path,
        state.tmp_path
      )

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
      tmp_path: state.tmp_path,
      workspace_path: state.workspace_path,
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
