defmodule Nest.Agents.AgentToolsSecondChanceTest do
  @moduledoc """
  Agent tool execution test for the max-iteration second-chance call.

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

  describe "max-iterations second-chance" do
    test "LLM ignoring tool_choice: :none triggers a second-chance call" do
      # The LLM hits the iteration cap. We then make a final
      # call with `tools: nil, tool_choice: :none`. Some
      # providers (e.g. qwen3.5-plus via model-studio) ignore
      # `tool_choice: :none` and still emit tool calls. The
      # runner must give the LLM one more chance via
      # synthetic error tool results, then force-finalize.
      #
      # Setup: 5 tool responses to exhaust the cap, then a
      # 6th tool response that the LLM should NOT honor (it
      # sees the synthetic errors), then a final text response
      # that the LLM produces after the second-chance
      # force-finalize.
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

      # The 6th response is what the LLM produces on the
      # max-iterations final call. It still emits tool calls
      # (ignoring tool_choice: :none). After the runner
      # synthesizes errors, the LLM sees them and gives a
      # final text response.
      MockClient.set_tool_response(%{
        text: "Trying one more tool",
        tool_calls: [
          %{
            id: "call_#{:rand.uniform(100_000)}",
            name: "context-check",
            arguments: %{}
          }
        ]
      })

      MockClient.set_response("Forced final answer after second-chance")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        :ok = Agent.chat(pid, "Exhaust iterations")

        # The max-iterations notification fires once.
        assert_receive {:chat_notification,
                        %{type: "max_iterations", message: "Max tool iterations reached"}},
                       3000

        # The chat eventually finalizes with the second-chance
        # forced text (no chat:error).
        assert_receive {:chat_message,
                        {:assistant,
                         %{
                           parts: [
                             %Part.Text{text: "Forced final answer after second-chance"}
                           ]
                         }}},
                       2000

        assert_receive {:chat_status, %{status: "idle"}}, 500
        refute_receive {:chat_error, _}, 500
      end)

      MockClient.clear()
    end
  end
end
