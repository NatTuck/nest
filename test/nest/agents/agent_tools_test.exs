defmodule Nest.Agents.AgentToolsTest do
  @moduledoc """
  Agent tool execution tests: `chat/2` with tool calls and
  `configured_max_tool_iterations/0`.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers
  alias Nest.TestSupport.AssistantWaiters

  describe "chat/2 with tool calls" do
    test "broadcasts complete tool call flow: user → assistant+tools → tool → assistant" do
      MockClient.set_tool_response(%{
        text: "I'll run that command for you",
        tool_calls: [
          %{id: "call_123", name: "shell_cmd", arguments: %{"command" => "ls -la"}}
        ]
      })

      MockClient.set_response("Here are the directory contents")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "List the files")

      # User message: first broadcast is empty, second carries the
      # request log. Match the second (non-empty api_logs).
      assert_receive {:chat_message,
                      {:user,
                       %{index: 1, parts: [%Part.Text{text: "[mode: chat]\nList the files"}]}}},
                     500

      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      # The first turn's assistant message carries the tool call.
      # A context-notice synthetic pair may also appear before it;
      # drain assistant messages until we find the one with the
      # expected tool call.
      msg_with_tool = AssistantWaiters.assistant_with_tool(pid, "call_123", 5_000)
      assert msg_with_tool != nil, "expected assistant with tool call id=call_123"
      assert msg_with_tool.index > 1
      assert Enum.any?(msg_with_tool.parts, &match?(%Part.ToolUse{id: "call_123"}, &1))

      assert_receive {:chat_status, %{status: "executing_tools"}}, 500
      assert_receive {:chat_message, {:tool, tool_msg}}
      assert tool_msg.index > msg_with_tool.index
      assert [%Part.ToolResult{}] = tool_msg.parts

      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      # The final assistant message carries the text response.
      # It must be the SECOND assistant (the first carries the
      # tool call), so drain to find it by content.
      final_msg =
        AssistantWaiters.assistant_with_text(pid, "Here are the directory contents", 5_000)

      assert final_msg != nil
      assert final_msg.index > tool_msg.index

      text_parts =
        Enum.filter(
          final_msg.parts,
          &match?(%Part.Text{text: "Here are the directory contents"}, &1)
        )

      assert text_parts != []

      assert_receive {:chat_status, %{status: "idle"}}, 500

      tool_call = Enum.find(msg_with_tool.parts, &match?(%Part.ToolUse{}, &1))
      assert tool_call.id == "call_123"
      assert tool_call.name == "shell_cmd"

      [tool_result] = tool_msg.parts
      assert tool_result.tool_call_id == "call_123"
      assert tool_result.name == "shell_cmd"
      assert tool_result.arguments == %{"command" => "ls -la"}

      MockClient.clear()
    end

    test "broadcasts status changes during tool execution flow" do
      MockClient.set_tool_response(%{
        text: "I'll run that command",
        tool_calls: [
          %{id: "call_789", name: "shell_cmd", arguments: %{"command" => "echo hello"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Run a command")

      # Each transition is a known broadcast in known order.
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_status, %{status: "executing_tools"}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_status, %{status: "idle"}}, 500

      MockClient.clear()
    end

    test "tool call message has correct content and tool_calls field" do
      MockClient.set_tool_response(%{
        text: "Let me calculate that",
        tool_calls: [
          %{id: "call_456", name: "calculator", arguments: %{"expression" => "2 + 2"}}
        ]
      })

      MockClient.set_response("The result is 4")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "What is 2+2?")

      assert_receive {:chat_message, {:user, _}}, 500

      # The first turn's assistant message carries the tool call.
      # A context-notice synthetic pair may shift the index; match
      # by content.
      msg_with_tool = AssistantWaiters.assistant_with_tool(pid, "call_456", 5_000)
      assert msg_with_tool != nil
      assert msg_with_tool.index > 1

      tool_call = Enum.find(msg_with_tool.parts, &match?(%Part.ToolUse{}, &1))
      assert tool_call.name == "calculator"
      assert tool_call.arguments == %{"expression" => "2 + 2"}

      assert_receive {:chat_status, %{status: "idle"}}, 500

      MockClient.clear()
    end

    test "tool result message has role tool not assistant" do
      MockClient.set_tool_response(%{
        text: "I'll check that",
        tool_calls: [
          %{id: "call_789", name: "weather", arguments: %{"city" => "London"}}
        ]
      })

      MockClient.set_response("The weather is sunny")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "What's the weather?")

      assert_receive {:chat_message, {:user, _}}, 500
      # The tool message index may shift if a context-notice
      # synthetic pair was injected. Match by content.
      assert_receive {:chat_message, {:tool, %Tool{parts: tool_results}}}, 500
      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert tool_results != []

      MockClient.clear()
    end

    test "second message after tool execution serializes tool results correctly" do
      MockClient.set_tool_response(%{
        text: "I'll check the directory",
        tool_calls: [
          %{id: "call_first", name: "shell_cmd", arguments: %{"command" => "ls"}}
        ]
      })

      MockClient.set_response("Directory listing complete")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "List files")
      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Drain all messages from the first turn so the second
      # turn's `assert_receive` calls don't accidentally match
      # a leftover message from turn 1.
      flush_all_messages()

      MockClient.set_response("Second response received")

      :ok = Agent.chat(pid, "What else is there?")

      # Indices shift based on context-notice synthetic pair
      # injections from the first turn. Match by content.
      assert_receive {:chat_message, {:user, second_user}}
      assert hd(second_user.parts).text == "[mode: chat]\nWhat else is there?"

      assert_receive {:chat_message, {:assistant, second_assistant}}

      assert Enum.any?(
               second_assistant.parts,
               &match?(%Part.Text{text: "Second response received"}, &1)
             )

      assert_receive {:chat_status, %{status: "idle"}}, 500

      MockClient.clear()
    end

    test "tool continuation flow broadcasts API calls for each LLM request" do
      MockClient.set_tool_response(%{
        text: "I'll execute that",
        tool_calls: [
          %{id: "call_api_001", name: "shell_cmd", arguments: %{"command" => "echo test"}}
        ]
      })

      MockClient.set_response("Tool executed successfully")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Run a command")

      # The tool message is re-broadcast after its api_logs are
      # populated. Drain tool messages until we find the one
      # with api_logs populated.
      tool_msg = wait_for_tool_with_api_logs(5_000)
      assert tool_msg != nil, "expected tool message with api_logs"
      tool_logs = tool_msg.api_logs
      assert tool_logs != []

      # The final assistant message is the SECOND one (the first
      # carries the tool call). Drain assistant messages until
      # we find one with a `Part.Text` matching the final response
      # and no `Part.ToolUse`.
      final_msg = wait_for_final_assistant("Tool executed successfully", 5_000)
      assert final_msg != nil, "expected final assistant message"
      assert final_msg.index > tool_msg.index
      final_logs = final_msg.api_logs
      assert final_logs != []

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert Enum.any?(tool_logs, fn log -> log.type == :request end),
             "Expected API request log in tool message"

      assert Enum.any?(final_logs, fn log -> log.type == :response end),
             "Expected API response log in final assistant message"

      MockClient.clear()
    end

    defp wait_for_final_assistant(wanted_text, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout

      do_wait_for_final_assistant(wanted_text, deadline)
    end

    defp do_wait_for_final_assistant(_text, deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        nil
      else
        receive do
          {:chat_message, {:assistant, msg}} ->
            if matches_final_assistant?(msg) and has_api_logs?(msg) do
              msg
            else
              do_wait_for_final_assistant("Tool executed successfully", deadline)
            end
        after
          100 -> do_wait_for_final_assistant("Tool executed successfully", deadline)
        end
      end
    end

    defp matches_final_assistant?(msg) do
      has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))

      has_text =
        Enum.any?(msg.parts, fn
          %Part.Text{text: text} -> text == "Tool executed successfully"
          _ -> false
        end)

      has_text and not has_tool_use
    end

    defp has_api_logs?(msg) do
      msg.api_logs != nil and msg.api_logs != []
    end

    defp wait_for_tool_with_api_logs(timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout

      do_wait_for_tool_with_api_logs(deadline)
    end

    defp do_wait_for_tool_with_api_logs(deadline) do
      if System.monotonic_time(:millisecond) >= deadline do
        nil
      else
        receive do
          {:chat_message, {:tool, msg}} ->
            if msg.api_logs != nil and msg.api_logs != [] do
              msg
            else
              do_wait_for_tool_with_api_logs(deadline)
            end
        after
          100 -> do_wait_for_tool_with_api_logs(deadline)
        end
      end
    end

    defp flush_all_messages do
      receive do
        _ -> flush_all_messages()
      after
        0 -> :ok
      end
    end

    test "broadcasts notification and produces final response when max tool iterations reached" do
      # The test config (test/data/config.toml) has max-tool-iterations = 5.
      # Set up MORE tool responses to ensure the limit is hit.
      for _ <- 1..10 do
        MockClient.set_tool_response(%{
          text: "Calling tool",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("I've completed the task after multiple iterations")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Keep looping")

        assert_receive {:chat_notification,
                        %{type: "max_iterations", message: "Max tool iterations reached"}},
                       500

        assert_receive {:chat_message,
                        {:assistant,
                         %{
                           parts: [
                             %Part.Text{text: "I've completed the task after multiple iterations"}
                           ]
                         }}},
                       500

        assert_receive {:chat_status, %{status: "idle"}}, 500
      end)

      MockClient.clear()
    end

    test "does NOT hit max-iterations when iterations stay below the configured cap" do
      for _ <- 1..2 do
        MockClient.set_tool_response(%{
          text: "Calling tool",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("Done well under the cap")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Brief loop")

      assert_receive {:chat_status, %{status: "idle"}}, 500
      refute_receive {:chat_notification, %{type: "max_iterations"}}, 500

      MockClient.clear()
    end

    test "max-iterations + LLM ignoring tool_choice: :none triggers a second-chance call" do
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
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
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
            name: "shell_cmd",
            arguments: %{"command" => "echo last"}
          }
        ]
      })

      MockClient.set_response("Forced final answer after second-chance")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

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
