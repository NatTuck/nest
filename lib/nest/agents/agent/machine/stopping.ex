defmodule Nest.Agents.Agent.Machine.Stopping do
  @moduledoc """
  The Stop transition (issue #36, step 4): stop everything the turn owns.

  Now that a message can interrupt a turn, Stop's remaining job is to end the
  turn and leave nothing running behind it: the turn's own worker, the batches
  it moved to the background, and the batch coordinators it reports to. Split
  out of `Machine.Transitions` for the credo file cap, and pure like the rest of
  the transition table.

  ## The cancellation record

  A killed backgrounded batch can never report a result, so the stop answers its
  promise here (decision D8): the transcript gains the runtime's cancellation
  notice and the assistant's acknowledgement of it, built by
  `Turn.Backgrounded.cancellation/1` and made wire-safe by
  `NoticePairInjector.notice_record/3`. It is an **append**, never an inbox
  entry — the stop's own `:stop_timer` transition drains the inbox, so an
  enqueued notice would start exactly the turn the human stopped.

  ## The timer comes last

  The stop arms the bounded `:stop_timer`, which owns the single terminal
  transition to `:idle`. `{:arm_timer, …}` yields a `{:timer_armed, …}` follow
  event, and the executor halts the action list on the first follow event, so
  the arm is the stop's last action and every action a stop cannot skip — the
  kills — is emitted before it.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Backgrounding
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.Turn.Backgrounded
  alias Nest.Agents.Agent.Turn.Terminal

  @doc """
  The `{:stop, channel}` event: the two no-op guards, then the stop itself.

  Idempotent — an already-stopping or already-idle agent is left untouched.
  """
  @spec stop(Machine.t(), pid() | nil) ::
          {:ok, [term()], Machine.t()} | {:ignore, atom(), Machine.t()}
  def stop(%Machine{phase: :stopping} = m, _channel), do: {:ignore, :already_stopping, m}
  def stop(%Machine{phase: :idle} = m, _channel), do: {:ignore, :already_idle, m}
  def stop(%Machine{} = m, channel), do: do_stop(m, channel)

  @doc "The `:stop_timer` event: the stop's single terminal transition."
  @spec stop_timer(Machine.t()) :: {:ok, [term()], Machine.t()}
  def stop_timer(%Machine{phase: :stopping} = m) do
    # `Transitions` dispatches this for `:stopping` alone, so a timer that fired
    # after the stop it belonged to already ended cannot rest a turn that has
    # since started.
    Phase.rest(%{m | stop_timer: nil}, m.kind, :stopped, [
      {:stop_all_children},
      {:finalize, Terminal.stopped_metadata()},
      {:drain_inbox}
    ])
  end

  @doc """
  The stop's response to a cancellation record the appender refused.

  The refusal halts the action list before `{:arm_timer, …}` runs, and the timer
  owns the single terminal transition, so a stop always arms it here: without
  the timer the turn would sit in `:stopping` forever. The record itself is lost
  — the transcript cannot show a cancellation that could not be written — so the
  warning is the only trace of it.
  """
  @spec record_refused(Machine.t(), atom(), String.t() | nil) :: {:ok, [term()], Machine.t()}
  def record_refused(m, outcome, reason) do
    detail = reason || Atom.to_string(outcome)

    {:ok,
     [
       {:log, :warning, "[stop] the cancellation record was refused: #{detail}"},
       {:arm_timer, Config.configured_stop_fallback_ms(), :stop_timer}
     ], m}
  end

  defp do_stop(m, channel) do
    actions =
      [{:ack, channel, :stopped}, {:set_cancelled, true}] ++
        coordinator_kills(m) ++
        Backgrounding.kill_actions(m) ++
        [{:stop_all_children}] ++
        timer_actions(m) ++
        worker_kills(m) ++
        cancellation_record(m) ++
        [{:arm_timer, Config.configured_stop_fallback_ms(), :stop_timer}]

    machine =
      Machine.validate!(%{
        m
        | phase: :stopping,
          stop_timer: nil,
          work: %{m.work | worker_kind: nil, active_worker_kind: nil, backgrounded: %{}}
      })

    {:ok, actions, machine}
  end

  # A batch coordinator is an unlinked task, so the stop must kill it too, or it
  # keeps spawning children and later delivers an aggregate the parent asked not
  # to have. Before `{:stop_all_children}`, which clears the map.
  defp coordinator_kills(m), do: Enum.map(Children.reporting_targets(m.children), &{:kill, &1})

  defp timer_actions(m) do
    if m.stop_timer, do: [{:cancel_timer, m.stop_timer}], else: []
  end

  defp worker_kills(m) do
    if m.work.active_worker, do: [{:kill, m.work.active_worker}], else: []
  end

  # One record for the whole stop, not one per killed batch: per-batch records
  # would repeat the same words and land as two consecutive assistant messages,
  # which the wire rejects. The count is what tells the model how many promises
  # were voided, and it counts the *calls* each entry answered, not the entries:
  # a three-call batch backgrounded once is three calls, and `map_size/1` would
  # call it one.
  defp cancellation_record(m) do
    case Backgrounding.call_count(m) do
      0 ->
        []

      count ->
        {notice, ack} = Backgrounded.cancellation(count)
        [{:append_many, NoticePairInjector.notice_record(transcript(m), notice, ack)}]
    end
  end

  # The transcript the appender will heal the tail of. A hand-built fixture can
  # have no turn context at all; with nothing to read the tail from, the record
  # is built for an empty list.
  defp transcript(%Machine{work: %{ctx: %{messages: messages}}}) when is_list(messages),
    do: messages

  defp transcript(_m), do: []
end
