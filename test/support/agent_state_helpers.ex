defmodule Nest.Agents.AgentStateHelpers do
  @moduledoc """
  The agent-state fixtures `Nest.Agents.Agent.InboxTest` and
  `Nest.Agents.Agent.InboxRenderTest` share.

  The two files were split out of one `AgentTest` module, and each carried its
  own copy of the status fixture, the settle wait and the `:sys.replace_state`
  wrapper. This is their single definition.

  `AgentTestHelpers` is the natural home for these, but it sits within a few
  lines of the 700-line cap, so they live here instead — a separate small
  module keeps it off the cap without one caller importing the other's file.
  """

  import ExUnit.Assertions

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine

  @doc "Force an agent's observable status (test-only; see `Machine.status_to_machine/2`)."
  @spec set_status(pid(), atom()) :: :ok
  def set_status(pid, status) do
    replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, status)}
      }
    end)
  end

  @doc """
  Wait for the agent to settle, on the frame that decides it: the `idle`
  broadcast that carries an empty queue. A bare `idle` frame is not the fence —
  a stop, and any turn end that drains, publishes the transient
  `streaming -> idle -> streaming` of issue #15 first — so the fence is the
  idle that carries an empty queue, which is also exactly the state no further
  drain can start from. The status read that follows is a read of the settled
  state, not a wait.
  """
  @spec wait_idle(pid()) :: :ok
  def wait_idle(pid) do
    assert_receive {:chat_status, %{status: "idle", pendingMessageCount: 0}}, 1_000

    assert Agent.get_public_info(pid, 1_000).status == :idle
  end

  @doc "`:sys.replace_state/3` with the suite's explicit 1 s timeout."
  @spec replace_state(pid(), (term() -> term())) :: term()
  def replace_state(pid, fun), do: :sys.replace_state(pid, fun, 1_000)
end
