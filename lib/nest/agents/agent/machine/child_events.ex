defmodule Nest.Agents.Agent.Machine.ChildEvents do
  @moduledoc """
  The child-agent lifecycle transitions, split out of `Machine.Transitions`.

  A parent's outstanding query children live in `Machine.Children`; this module
  maps the five lifecycle events the parent receives — `:child_spawned`,
  `:child_completed`, `:child_failed`, `:child_terminated` and
  `:abandon_child` — onto that sub-machine, and adds the turn-boundary work the
  parent needs around each one.

  Every clause is a pure function of `(machine, event)`, like the rest of the
  transition table: it returns the actions the executor must run and the next
  machine.
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children

  @doc "Apply one child lifecycle event to the parent machine."
  @spec transition(Machine.t(), term()) ::
          {:ok, [term()], Machine.t()} | {:ignore, atom(), Machine.t()}
  def transition(%Machine{} = m, {:child_spawned, name, archive, target}) do
    case Children.register(m.children, name, archive, target) do
      {:ok, _actions, children} -> {:ok, [], %{m | children: children}}
      {:ignore, reason, children} -> {:ignore, reason, %{m | children: children}}
    end
  end

  def transition(%Machine{} = m, {:child_completed, name, response, usage}) do
    child_event(m, {:completed, name, response, usage})
  end

  def transition(%Machine{} = m, {:child_failed, name, reason}) do
    child_event(m, {:failed, name, reason})
  end

  def transition(%Machine{} = m, {:child_terminated, name, reason}) do
    child_event(m, {:terminated, name, reason})
  end

  def transition(%Machine{} = m, {:abandon_child, name}) do
    child_event(m, {:abandoned, name})
  end

  # A child's outcome is delivered into this agent's own inbox (§2.1). When the
  # machine is already idle, nothing else would ever drain it: a peer's message
  # wakes an idle agent (`Inbox.handle_delivery/4` drains it), and a child's
  # answer has to as well — otherwise a parent that ended its turn before its
  # child answered would leave the answer sitting in the queue until something
  # else woke it. While the parent is `:generating` the `:iterate` turn boundary
  # drains it instead. `:executing_tools` needs the drain too (issue #36): an
  # internal enqueue never passes through the delivery path, so this is the only
  # thing that can background the parent's batch and deliver the answer now.
  defp child_event(m, event) do
    case Children.step(m.children, event) do
      {:ok, actions, children} ->
        actions = actions ++ [{:broadcast, :status, nil}]

        drain = if m.phase in [:idle, :executing_tools], do: [{:drain_inbox}], else: []
        {:ok, actions ++ drain, %{m | children: children}}

      {:ignore, reason, children} ->
        {:ignore, reason, %{m | children: children}}
    end
  end
end
