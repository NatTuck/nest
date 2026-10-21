defmodule Nest.Agents.AgentToolsTest do
  @moduledoc """
  Agent tool execution tests: `chat/2` with tool calls and the
  message-shape contract for a full tool round. The max-iteration and
  second-chance flows live in `AgentToolsMaxIterationsTest` /
  `AgentToolsSecondChanceTest` so the `bwrap`-heavy rounds don't extend
  this module's critical path.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

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

      :ok = Agent.chat(pid, "List the files", nil, nil, :composed)

      # User message: first broadcast is empty, second carries the
      # request log. Match the second (non-empty api_logs).
      assert_receive {:chat_message,
                      {:user,
                       %{
                         index: 1,
                         parts: [%Part.Text{text: "[From user | mode: act]\nList the files"}]
                       }}},
                     500

      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      assert_receive {:chat_delta, _}, 1_000

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

      assert %Part.ToolUse{id: "call_123", name: "shell-cmd"} =
               Enum.find(msg_with_tool.parts, &match?(%Part.ToolUse{}, &1))

      assert_receive {:chat_status, %{status: "executing_tools"}}, 1_000
      assert_receive {:chat_message, {:tool, tool_msg}}, 1_000
      assert [%Part.ToolResult{} = tool_result] = tool_msg.parts

      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      assert_receive {:chat_delta, _}, 1_000

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

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      assert tool_result.tool_call_id == "call_123"
      assert tool_result.name == "shell-cmd"
      assert tool_result.arguments == %{"command" => "ls -la"}

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

      :ok = Agent.chat(pid, "List files", nil, nil, :composed)
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # drain loop killed with fire, it can *NEVER EVER* come back

      MockClient.set_response("Second response received")

      :ok = Agent.chat(pid, "What else is there?", nil, nil, :composed)

      # Indices shift based on context-notice synthetic pair
      # injections from the first turn. Match by content (first
      # part text). Turn 1's user starts with "List files"; turn 2's
      # starts with "What else is there?" — only turn 2 matches.
      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[From user | mode: act]\nWhat else is there?"}]
                       }}},
                     500

      # First turn's assistant starts with `%Part.ToolUse{}`; turn 2's
      # starts with `%Part.Text{text: "Second response received"}`.
      # The pattern matches only turn 2's assistant.
      assert_receive {:chat_message,
                      {:assistant, %{parts: [%Part.Text{text: "Second response received"} | _]}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      MockClient.clear()
    end
  end
end
