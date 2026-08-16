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

  # drain loop killed with fire, it can *NEVER EVER* come back
  # — Nest.TestSupport.AgentToolsWaiters / AssistantWaiters
  # are gone. Use `assert_receive` per AGENTS.md.

  describe "chat/2 with tool calls" do
    test "broadcasts complete tool call flow: user → assistant+tools → tool → assistant" do
      MockClient.set_tool_response(%{
        text: "I'll run that command for you",
        tool_calls: [
          %{id: "call_123", name: "shell-cmd", arguments: %{"command" => "ls -la"}}
        ]
      })

      MockClient.set_response("Here are the directory contents")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "List the files")

      # User message: first broadcast is empty, second carries the
      # request log. Match the second (non-empty api_logs).
      assert_receive {:chat_message,
                      {:user,
                       %{index: 1, parts: [%Part.Text{text: "[mode: chat]\nList the files"}]}}},
                     500

      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      # drain loop killed with fire, it can *NEVER EVER* come back.
      # Precise single-message pattern: the first assistant's first
      # part is the "I'll run that command for you" text. The test's
      # MockClient.set_tool_response/1 places Text FIRST in the
      # parts list (the tool_use follows). Use the unique text to
      # distinguish this from context-notices and turn 2's assistant.
      assert_receive {:chat_message,
                      {:assistant,
                       %{
                         parts: [%Part.Text{text: "I'll run that command for you"} | _]
                       } = msg_with_tool}},
                     500

      tool_call =
        Enum.find(msg_with_tool.parts, &match?(%Part.ToolUse{id: "call_123"}, &1))

      assert tool_call, "expected tool call with id=call_123"
      assert tool_call.id == "call_123"
      assert tool_call.name == "shell-cmd"

      assert_receive {:chat_status, %{status: "executing_tools"}}, 500
      assert_receive {:chat_message, {:tool, tool_msg}}
      assert [%Part.ToolResult{}] = tool_msg.parts

      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      # drain loop killed with fire, it can *NEVER EVER* come back.
      # Precise single-message pattern: the final assistant's first
      # part is `%Part.Text{text: "Here are the directory contents"}`,
      # so this matches only that one message — turn-1 assistant
      # (starts with `%Part.ToolUse{}`) and any context-notice pair
      # (different text) stay in the mailbox untouched.
      assert_receive {:chat_message,
                      {:assistant,
                       %{parts: [%Part.Text{text: "Here are the directory contents"} | _]}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500

      [tool_result] = tool_msg.parts
      assert tool_result.tool_call_id == "call_123"
      assert tool_result.name == "shell-cmd"
      assert tool_result.arguments == %{"command" => "ls -la"}

      MockClient.clear()
    end

    test "broadcasts status changes during tool execution flow" do
      MockClient.set_tool_response(%{
        text: "I'll run that command",
        tool_calls: [
          %{id: "call_789", name: "shell-cmd", arguments: %{"command" => "echo hello"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "What is 2+2?")

          assert_receive {:chat_message, {:user, _}}, 500

          # drain loop killed with fire, it can *NEVER EVER* come back

          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      # The tool name `calculator` isn't in the programmer
      # vocation (it's intentionally not — this test only
      # verifies message-shape, not actual tool execution), so
      # BatchSizer correctly emits `is_error: true` and the
      # permanent diagnostic below.
      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "tool=calculator"

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "What's the weather?")

          assert_receive {:chat_message, {:user, _}}, 500
          assert_receive {:chat_message, {:tool, %Tool{parts: tool_results}}}, 500
          assert_receive {:chat_status, %{status: "idle"}}, 500

          assert tool_results != []
        end)

      # `weather` isn't a real tool — this test verifies the
      # chat-message shape on the tool-result side. BatchSizer
      # emits the standard is_error diagnostic when the tool
      # lookup fails.
      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "tool=weather"

      MockClient.clear()
    end

    test "second message after tool execution serializes tool results correctly" do
      MockClient.set_tool_response(%{
        text: "I'll check the directory",
        tool_calls: [
          %{id: "call_first", name: "shell-cmd", arguments: %{"command" => "ls"}}
        ]
      })

      MockClient.set_response("Directory listing complete")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "List files")
      assert_receive {:chat_status, %{status: "idle"}}, 500

      # drain loop killed with fire, it can *NEVER EVER* come back

      MockClient.set_response("Second response received")

      :ok = Agent.chat(pid, "What else is there?")

      # Indices shift based on context-notice synthetic pair
      # injections from the first turn. Match by content (first
      # part text). Turn 1's user starts with "List files"; turn 2's
      # starts with "What else is there?" — only turn 2 matches.
      assert_receive {:chat_message,
                      {:user,
                       %{parts: [%Part.Text{text: "[mode: chat]\nWhat else is there?"}]} =
                         second_user}},
                     500

      assert hd(second_user.parts).text == "[mode: chat]\nWhat else is there?"

      # First turn's assistant starts with `%Part.ToolUse{}`; turn 2's
      # starts with `%Part.Text{text: "Second response received"}`.
      # The pattern matches only turn 2's assistant.
      assert_receive {:chat_message,
                      {:assistant,
                       %{parts: [%Part.Text{text: "Second response received"} | _]} =
                         second_assistant}},
                     500

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
          %{id: "call_api_001", name: "shell-cmd", arguments: %{"command" => "echo test"}}
        ]
      })

      MockClient.set_response("Tool executed successfully")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Run a command")

      # drain loop killed with fire, it can *NEVER EVER* come back.
      # Assistant messages are broadcast TWICE: once initially (empty
      # `api_logs`) and once after the LLM turn completes (populated).
      # Require non-empty `api_logs` on every wait to skip the empty
      # initial broadcast.
      assert_receive {:chat_message,
                      {:assistant,
                       %{
                         parts: [%Part.Text{text: "I'll execute that"} | _],
                         api_logs: [_ | _]
                       } = first_assistant}},
                     500

      _ = first_assistant

      assert_receive {:chat_message, {:tool, %{api_logs: [_ | _]} = tool_msg}},
                     500

      tool_logs = tool_msg.api_logs

      assert_receive {:chat_message,
                      {:assistant,
                       %{
                         parts: [%Part.Text{text: "Tool executed successfully"} | _],
                         api_logs: [_ | _]
                       } = final_msg}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500
      final_logs = final_msg.api_logs

      assert Enum.any?(tool_logs, fn log -> log.type == :request end),
             "Expected API request log in tool message"

      assert Enum.any?(final_logs, fn log -> log.type == :response end),
             "Expected API response log in final assistant message"

      MockClient.clear()
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
              name: "shell-cmd",
              arguments: %{"command" => "echo loop"}
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
              name: "shell-cmd",
              arguments: %{"command" => "echo loop"}
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
              name: "shell-cmd",
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
            name: "shell-cmd",
            arguments: %{"command" => "echo last"}
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
