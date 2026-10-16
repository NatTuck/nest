defmodule Nest.Agents.Agent.Turn.ChildActions do
  @moduledoc """
  The executor's child/sub-agent actions.

  `Turn.Executor` dispatches the child lifecycle actions here the way it
  dispatches the reply give-up to `Turn.GiveUpDelivery`: the executor owns the
  action vocabulary, and this module owns what each child action does to the
  live agent. Split out of `Turn.Executor` for the credo file cap.

  A child's outcome is delivered here, in the parent's process, so a child whose
  worker is already gone cannot lose the result — there is no `send/2` to a pid
  left to fail (issue #31 §2.1). It goes to the child's *reporting target* when
  it has one that is still alive: a batch child reports to its coordinator, so
  the parent reads the batch's aggregate once instead of every child's answer as
  well. A target that has died falls back to the parent's own inbox, so a batch
  whose coordinator crashed degrades to per-child messages rather than to
  silence. The completion arrives as the child's own words; a child that
  produced nothing, failed, or was stopped arrives as a runtime notice.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Agents.Agent.Timeline
  alias Nest.Agents.Agent.Watch

  @doc "Deliver a child's outcome to its reporting target, or the parent's inbox."
  @spec child_message(Agent.t(), String.t(), term()) :: {Agent.t(), :continue}
  def child_message(state, name, result) do
    Timeline.child_message(state, name, result)

    case Children.target(state.live.machine.children, name) do
      target when is_pid(target) ->
        if Process.alive?(target) do
          send(target, {:child_message, name, result})
          {state, :continue}
        else
          enqueue_child_message(state, name, result)
        end

      nil ->
        enqueue_child_message(state, name, result)
    end
  end

  @doc "Merge a child's token usage into the parent's descendant totals."
  @spec merge_usage(Agent.t(), String.t(), term()) :: {Agent.t(), :continue}
  def merge_usage(state, name, usage) do
    Timeline.child_usage(state, name, usage)

    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | descendant_usage: Broadcasts.total_usage(state.llm_metrics.descendant_usage, usage)
        }
    }

    {state, :continue}
  end

  @doc "Stop one child by name."
  @spec stop_child(Agent.t(), String.t()) :: {Agent.t(), :continue}
  def stop_child(state, name) do
    Timeline.child_action(state, "stopped", name)
    _ = Nest.Agents.Supervisor.stop_agent(state.space_id, name)
    {state, :continue}
  end

  @doc "Archive one child by name."
  @spec archive_child(Agent.t(), String.t()) :: {Agent.t(), :continue}
  def archive_child(state, name) do
    Timeline.child_action(state, "archived", name)
    _ = Nest.Agents.Supervisor.archive_agent(state.space_id, name)
    {state, :continue}
  end

  @doc "Stop every running child and drop the parent's child bookkeeping."
  @spec stop_all(Agent.t()) :: {Agent.t(), :continue}
  def stop_all(state) do
    machine = state.live.machine

    machine
    |> Machine.running_child_names()
    |> Enum.each(fn name -> _ = Nest.Agents.Supervisor.stop_agent(state.space_id, name) end)

    {%{state | live: %{state.live | machine: %{machine | children: Children.new()}}}, :continue}
  end

  @doc "Stop every file watch the agent holds."
  @spec stop_watchers(Agent.t()) :: {Agent.t(), :continue}
  def stop_watchers(state), do: {Watch.stop_all(state), :continue}

  defp enqueue_child_message(state, name, result) do
    {content, kind} = SubAgentResults.child_message(name, result)
    {Inbox.enqueue_internal(state, name, content, kind), :continue}
  end
end
