defmodule Nest.Agents.Agent.Turn.Idle do
  @moduledoc """
  The single runtime on-enter-`:idle` hook.

  `enter/1` is the machine's idle transition plus the one place that
  drains queued async agent-to-agent messages: it moves the machine to
  `:idle` (via `Machine.to_idle/1`), broadcasts the status, then calls
  `Nest.Agents.Agent.Inbox.drain_if_idle/1`. Every idle transition in
  the Agent funnels through here.

  `drain/1` is the drain-only variant for callers that have already
  decided the machine state (e.g. a post-compaction resume that may or
  may not end idle): it drains iff the agent is idle, and is otherwise
  a no-op. Both paths share the single `Inbox.drain_if_idle/1`
  implementation, so queued messages can only ever start one turn.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine

  @doc "Transition to idle, broadcast the status, and drain the inbox."
  @spec enter(Agent.t()) :: Agent.t()
  def enter(state) do
    state = put_idle(state)
    Broadcasts.status(state)
    drain(state)
  end

  @doc "Drain the inbox iff the agent is idle. No-op otherwise."
  @spec drain(Agent.t()) :: Agent.t()
  def drain(state), do: Inbox.drain_if_idle(state)

  defp put_idle(state) do
    %{state | live: %{state.live | machine: Machine.to_idle(state.live.machine)}}
  end
end
