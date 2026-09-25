defmodule Nest.Agents.AgentToolsIterationsTest do
  @moduledoc """
  Agent tool execution test for iterations staying below the cap.

  The multi-round cap and second-chance flows live in
  `AgentToolsMaxIterationsTest` / `AgentToolsSecondChanceTest` so each
  runs on its own ExUnit worker.
  """
  use Nest.DataCase, async: true

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

      assert_receive {:chat_status, %{status: "idle"}}, 500
      refute_receive {:chat_notification, %{type: "max_iterations"}}, 500

      MockClient.clear()
    end
  end
end
