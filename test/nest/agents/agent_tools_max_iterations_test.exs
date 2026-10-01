defmodule Nest.Agents.AgentToolsMaxIterationsTest do
  @moduledoc """
  Agent tool execution test for hitting the max-iteration cap.

  Split from `AgentToolsIterationsTest` so this multi-round flow runs
  on its own ExUnit worker.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

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
      # The cap is 5 (test/data/config.toml). Resuming a turn that is
      # already at the cap exercises the same path as looping a user chat
      # up to it, in one LLM round instead of six: the carried
      # `{:tool_call, msg, iter, max}` continuation preserves both
      # counters, so the turn is over the cap before its first LLM call.
      MockClient.set_response("I've completed the task after multiple iterations")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        send_compaction_done(pid, "Summary", {:tool_call, carried_tool_call_msg(), 5, 5})

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

  # The carried assistant+ToolUse handed to a resumed turn via
  # `{:compaction_done, "…", {:tool_call, msg, iter, max}}`. The resumed
  # turn executes it first (Trigger 2), then makes its next LLM call with
  # the carried iteration count — so seeding a turn at the cap makes that
  # call the final `tools: nil` one. `context-check` (rather than
  # `context-compact`) keeps the execution from triggering a compaction
  # of its own.
  defp carried_tool_call_msg do
    {:assistant,
     %Nest.Messages.Assistant{
       index: 0,
       parts: [
         %Part.ToolUse{
           id: "call_cap",
           name: "context-check",
           arguments: %{}
         }
       ],
       api_logs: []
     }}
  end
end
