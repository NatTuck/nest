defmodule Nest.Agents.AgentToolsIterationsTest do
  @moduledoc """
  Agent tool execution test for iterations staying below the cap.

  The multi-round cap and second-chance flows live in
  `AgentToolsMaxIterationsTest` / `AgentToolsSecondChanceTest` so each
  runs on its own ExUnit worker.
  """
  use Nest.DataCase, async: true

  # `Agent.chat/2` is a `GenServer.cast`, so a fence placed after it covers the
  # *whole* turn: here three sequential LLM calls plus real tool execution
  # through the GenServer/DB pipeline. 500 ms is not a bound for that under
  # load, and the end of the turn is decided by arrival, not by the clock:
  # `AgentTestHelpers.start_agent/1` subscribes this test pid to the agent's
  # topic, so the machine's `idle` `chat:status` frame — broadcast when the
  # settle loop leaves the turn — is the event that ends it. `@turn_fence_ms` is
  # only the failure bound.
  @turn_fence_ms 1_000

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "iterations below the cap" do
    test "does NOT hit max-iterations when iterations stay below the configured cap" do
      for _ <- 1..2 do
        MockClient.set_tool_response(%{
          text: "Calling tool",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "context-check",
              arguments: %{}
            }
          ]
        })
      end

      MockClient.set_response("Done well under the cap")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Brief loop")

      # `Agent.chat/5` is a cast, so the `idle` `chat:status` frame is the
      # arrival-decided end of this turn. This turn drives three sequential LLM
      # calls plus tool execution through the GenServer/DB pipeline under
      # 24-way async concurrency, so `@turn_fence_ms` is the failure bound, not
      # the synchronisation.
      assert_receive {:chat_status, %{status: "idle"}}, @turn_fence_ms

      # Below the cap, `max_iterations` is never broadcast. If it ever were,
      # it would be emitted before idle, so this non-blocking check is
      # deterministic.
      refute_received {:chat_notification, %{type: "max_iterations"}}

      MockClient.clear()
    end
  end
end
