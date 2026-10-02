defmodule Nest.Agents.AgentToolsSecondChanceTest do
  @moduledoc """
  Agent tool execution test for the max-iteration second-chance call.

  Split from `AgentToolsIterationsTest` so this multi-round flow runs
  on its own ExUnit worker.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

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
      # The turn is at the cap, so its first LLM call is the final
      # `tools: nil, tool_choice: :none` one. Some providers (e.g.
      # qwen3.5-plus via model-studio) ignore `tool_choice: :none` and
      # still emit tool calls. The runner must give the LLM one more
      # chance via synthetic error tool results, then force-finalize.
      #
      # The overflow round is scripted as raw events rather than a
      # `set_tool_response/1` entry: the `tools: nil` lookup
      # deliberately skips queued tool responses (that is how an
      # *obedient* provider is simulated), so a `{:tool, _}` entry can
      # never come back on this call.
      MockClient.set_stream_events([
        {:text, "Trying one more tool"},
        {:tool_call_start, %{id: "call_overflow", name: "context-check"}},
        {:tool_call_delta, %{id: "call_overflow", arguments_delta: "{}"}},
        {:finish_reason, "tool_calls"}
      ])

      # What the LLM produces once it sees the synthetic errors.
      MockClient.set_response("Forced final answer after second-chance")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        send_compaction_done(pid, "Summary", {:tool_call, carried_tool_call_msg(), 5, 5})

        # The max-iterations notification fires once.
        assert_receive {:chat_notification,
                        %{type: "max_iterations", message: "Max tool iterations reached"}},
                       750

        # The chat finalizes with the second-chance forced text.
        assert_receive {:chat_message,
                        {:assistant,
                         %{
                           parts: [
                             %Part.Text{text: "Forced final answer after second-chance"}
                           ]
                         }}},
                       750

        assert_receive {:chat_status, %{status: "idle"}}, 750
        refute_receive {:chat_error, _}, 200
      end)

      # The synthetic error tool results are the evidence that the
      # second-chance path ran at all — without them the turn would have
      # finalized on the obedient path, exactly as it did before the
      # overflow round was scripted as events.
      state = :sys.get_state(pid)

      assert Enum.any?(state.chat_state.messages, fn
               {:tool, %Tool{parts: parts}} ->
                 Enum.any?(parts, fn
                   %Part.ToolResult{is_error: true, content: content} ->
                     String.contains?(content, "Maximum tool iterations reached")

                   _ ->
                     false
                 end)

               _ ->
                 false
             end),
             "expected the synthetic max-iterations error tool results"

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
     %Assistant{
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
