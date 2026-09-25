defmodule Nest.Agents.AgentToolsMaxIterationsTest do
  @moduledoc """
  Agent tool execution test for hitting the max-iteration cap.

  Split from `AgentToolsIterationsTest` so this multi-round flow runs
  on its own ExUnit worker.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "max tool iterations" do
    test "broadcasts notification and produces final response when max tool iterations reached" do
      # The test config (test/data/config.toml) has max-tool-iterations = 5.
      # Queue 5 tool responses (one per iteration) to hit the limit.
      for _ <- 1..5 do
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

      MockClient.set_response("I've completed the task after multiple iterations")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        :ok = Agent.chat(pid, "Keep looping")

        assert_receive {:chat_notification,
                        %{type: "max_iterations", message: "Max tool iterations reached"}},
                       750

        assert_receive {:chat_message,
                        {:assistant,
                         %{
                           parts: [
                             %Part.Text{text: "I've completed the task after multiple iterations"}
                           ]
                         }}},
                       750

        assert_receive {:chat_status, %{status: "idle"}}, 750
      end)

      MockClient.clear()
    end
  end
end
