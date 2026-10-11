defmodule Nest.Agents.Agent.Machine.Failure do
  @moduledoc """
  Worker-death handling for the agent machine, grouped out of
  `Nest.Agents.Agent.Machine.Transitions` to keep the transition table
  within its file-length budget.

  `worker_down/3` is the identity test a `{:worker_down, pid, reason}`
  reaches once a backgrounded pid and a compactor machine have been ruled
  out: the turn's own worker fails the turn (or recovers an interrupted
  tool batch), and any other pid is ignored. The `cond` it delegates to,
  the interrupted-tool recovery, and the turn-failure funnel are a pure
  move from the transition table; behavior is unchanged.
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.Agent.Turn.Terminal

  @doc "The turn's own worker died: fail or recover, per its kind and reason."
  @spec worker_down(Machine.t(), term(), term()) ::
          {:ok, [Machine.action()], Machine.t()} | {:ignore, atom(), Machine.t()}
  def worker_down(m, pid, reason) do
    if is_pid(pid) and pid == m.work.active_worker do
      crash(m, reason)
    else
      {:ignore, :unknown_worker_down, m}
    end
  end

  @doc """
  End the turn with a failure: persist the partial, rest `:idle`, and
  drain. Shared by the transition table's own failure sites.
  """
  @spec fail_turn(Machine.t(), term(), [term()]) :: {:ok, [Machine.action()], Machine.t()}
  def fail_turn(m, reason, stacktrace) do
    Phase.rest(Phase.clear_worker(m), :chat, :turn_failed, [
      {:fail_turn, reason, stacktrace},
      {:drain_inbox}
    ])
  end

  # The turn's own worker is gone; its kind and reason decide the outcome.
  defp crash(m, reason) do
    cond do
      m.work.active_worker_kind == :tools ->
        recover_interrupted_tool(m)

      reason == :normal ->
        {:ok, [], Phase.clear_worker(m)}

      reason in [:shutdown, :killed] or match?({:shutdown, _}, reason) ->
        Phase.rest(Phase.clear_worker(m), :chat, :stopped, [
          {:finalize, Terminal.stopped_metadata()},
          {:drain_inbox}
        ])

      true ->
        fail_turn(m, reason, [])
    end
  end

  defp recover_interrupted_tool(m) do
    case Repair.decide(:worker_death, m.work.ctx.messages, nil) do
      :none ->
        Phase.rest(Phase.clear_worker(m), :chat, :interrupted_tool, [
          {:finalize, Terminal.stopped_metadata()},
          {:drain_inbox}
        ])

      {:repair, [tool_msg]} ->
        machine = Phase.enter(Phase.clear_worker(m), :chat, :generating, :http)

        {:ok,
         [
           {:log, :warning, "tool worker died; answering tool_use with an error result"},
           {:append, tool_msg},
           :iterate
         ], machine}
    end
  end
end
