defmodule Nest.Agents.Agent.IdleFenceTest do
  @moduledoc """
  The idle fence's own contract.

  `SubAgentToolsHelpers.await_idle/1` is decided by the arrival of the agent's
  `{:chat_status, %{name: name, status: "idle"}}` frame, so a fence whose frame
  never arrives has to time out. That is what makes it a fence rather than a
  check: the poll it replaced read `Machine.status_for/1`, and an agent that has
  never run a turn is idle from the moment it starts — so the poll would report
  success on an agent that broadcast nothing at all, and a broadcast regression
  could pass as a pass.
  """

  use Nest.DataCase, async: true

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.SubAgentToolsHelpers

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "the fence is the idle frame: it fails without one, and passes with one" do
    {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}})

    # No turn has run, so no `idle` frame has been broadcast — the agent is
    # nonetheless idle, which is exactly what a state-reading wait would report
    # as success. The fence must not: it burns its own bound (1000 ms) and fails
    # as a missing frame, not as a state that was wrong.
    assert_raise ExUnit.AssertionError, ~r/no matching message after 1000ms/, fn ->
      await_idle(name)
    end

    # The same fence, on the frame the turn ends on: `Agent.chat/2` casts, so the
    # `idle` broadcast is the turn's last frame and every earlier frame of it
    # precedes this one in the mailbox.
    MockClient.set_response("hello")
    :ok = Agent.chat(pid, "hi")

    assert await_idle(name) == :ok
  end
end
