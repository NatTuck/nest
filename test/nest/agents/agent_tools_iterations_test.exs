defmodule Nest.Agents.AgentToolsIterationsTest do
  @moduledoc """
  Agent tool execution test for iterations staying below the cap.

  The multi-round cap and second-chance flows live in
  `AgentToolsMaxIterationsTest` / `AgentToolsSecondChanceTest` so each
  runs on its own ExUnit worker.
  """
  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Eventually
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

      # Wait for the turn to actually finish by polling the agent's status
      # rather than a fixed wall-clock window: this turn drives three
      # sequential LLM calls plus tool execution through the GenServer/DB
      # pipeline under 24-way async concurrency, so a 500ms receive is not a
      # deterministic bound.
      assert eventually(
               fn ->
                 Machine.status_for(:sys.get_state(pid).live.machine) == :idle
               end,
               timeout: 1_000
             )

      # Below the cap, `max_iterations` is never broadcast. If it ever were,
      # it would be emitted before idle, so this non-blocking check is
      # deterministic.
      refute_received {:chat_notification, %{type: "max_iterations"}}

      MockClient.clear()
    end
  end
end
