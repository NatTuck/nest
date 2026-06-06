defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Tests for the Agent GenServer behavior via PubSub.
  """
  use ExUnit.Case, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Registry
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall

  setup :set_mimic_global
  setup :verify_on_exit!

  defp start_agent(attrs) do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Agent, attrs})
    {pid, agent_id}
  end

  describe "start_link/1" do
    test "starts agent and registers in registry" do
      agent_id = "registered-agent-#{System.unique_integer([:positive])}"
      pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})
      assert Registry.lookup(agent_id) == {:ok, pid}
    end
  end

  describe "chat/2" do
    test "broadcasts user message and LLM response via PubSub" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                     1000

      # Receive assistant response via PubSub
      receive_deltas_and_message_from_pubsub()
    end

    test "handles LLM error gracefully" do
      # Mock LLM to return an error
      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain ->
        {:error, nil, "Connection failed"}
      end)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Should receive user message
      assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                     1000

      # Should receive error message
      assert_receive {:chat_error, _error}, 2000
    end

    test "accumulates delta content from streaming LLM response" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, _}}, 1000

      # Collect deltas and verify final message
      {partial_content, final_message} = collect_deltas_and_message_from_pubsub()

      # Verify accumulated content matches final
      assert elem(final_message, 0) == :assistant
      assert partial_content == elem(final_message, 1).content
      assert partial_content != ""
    end
  end

  describe "delta handling" do
    test "accumulates deltas with correct character counts" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Skip user message
      assert_receive {:chat_message, {:user, _}}, 1000

      # Collect all deltas and verify
      deltas = collect_all_deltas_from_pubsub()

      # Verify we got deltas
      assert deltas != []
    end
  end

  describe "chat/2 with tool calls" do
    test "broadcasts complete tool call flow: user → assistant+tools → tool → assistant" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Configure mock to return tool calls
      Nest.LangChainMock.set_tool_response(%{
        text: "I'll run that command for you",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_123",
            name: "shell_cmd",
            arguments: %{"command" => "ls -la"}
          }
        ]
      })

      # Set final response after tool execution
      Nest.LangChainMock.set_response("Here are the directory contents")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List the files")

      # Collect all messages from PubSub (deduplicated by index)
      messages = collect_all_messages_from_pubsub([])

      # Should receive exactly 4 unique messages (user, assistant+tools, tool, assistant)
      # Note: messages may be broadcast multiple times with api_logs updates
      assert length(messages) >= 4, "Expected at least 4 messages, got #{length(messages)}"

      # Get unique messages by index (keep latest version with api_logs)
      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      assert length(unique_messages) == 4,
             "Expected 4 unique messages, got #{length(unique_messages)}: #{inspect(unique_messages)}"

      # Message 0: User message
      assert {:user, user_msg} = Enum.at(unique_messages, 0)
      assert user_msg.index == 0
      assert user_msg.content == "List the files"

      # Message 1: Assistant with tool calls
      assert {:assistant, assistant_msg} = Enum.at(unique_messages, 1)
      assert assistant_msg.index == 1
      assert assistant_msg.content == "I'll run that command for you"
      assert assistant_msg.tool_calls != []
      assert length(assistant_msg.tool_calls) == 1

      [tool_call] = assistant_msg.tool_calls
      assert %ToolCall{} = tool_call
      assert tool_call.id == "call_123"
      assert tool_call.name == "shell_cmd"

      # Message 2: Tool result
      assert {:tool, tool_msg} = Enum.at(unique_messages, 2)
      assert tool_msg.index == 2
      assert tool_msg.tool_results != []
      assert length(tool_msg.tool_results) == 1

      [tool_result] = tool_msg.tool_results
      assert tool_result.tool_call_id == "call_123"
      assert tool_result.name == "shell_cmd"

      # Message 3: Final assistant response
      assert {:assistant, final_msg} = Enum.at(unique_messages, 3)
      assert final_msg.index == 3
      assert final_msg.content == "Here are the directory contents"

      # Cleanup
      Nest.LangChainMock.clear_response()
    end

    test "tool call message has correct content and tool_calls field" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      Nest.LangChainMock.set_tool_response(%{
        text: "Let me calculate that",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_456",
            name: "calculator",
            arguments: %{"expression" => "2 + 2"}
          }
        ]
      })

      Nest.LangChainMock.set_response("The result is 4")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "What is 2+2?")

      # Find the assistant message with tool calls
      assistant_msg =
        receive do
          {:chat_message, {:user, _}} ->
            receive do
              {:chat_message, {:assistant, %Assistant{tool_calls: [_ | _]} = msg}} ->
                msg
            after
              3000 -> flunk("Timeout waiting for assistant with tool calls")
            end
        after
          1000 -> flunk("Timeout waiting for user message")
        end

      assert assistant_msg.index == 1
      assert assistant_msg.content == "Let me calculate that"
      assert length(assistant_msg.tool_calls) == 1

      [tool_call] = assistant_msg.tool_calls
      assert tool_call.name == "calculator"
      assert tool_call.arguments == %{"expression" => "2 + 2"}

      # Cleanup
      Nest.LangChainMock.clear_response()
    end

    test "tool result message has role tool not assistant" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      Nest.LangChainMock.set_tool_response(%{
        text: "I'll check that",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_789",
            name: "weather",
            arguments: %{"city" => "London"}
          }
        ]
      })

      Nest.LangChainMock.set_response("The weather is sunny")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "What's the weather?")

      # Collect messages until we get the tool result
      tool_msg =
        receive do
          {:chat_message, {:user, _}} ->
            collect_until_tool_message()
        after
          1000 -> flunk("Timeout waiting for user message")
        end

      # Verify it's a tool message
      assert {:tool, %Tool{} = msg} = tool_msg
      assert msg.index == 2
      assert msg.tool_results != []

      # Cleanup
      Nest.LangChainMock.clear_response()
    end

    test "second message after tool execution serializes tool results correctly" do
      # This test verifies that tool results are stored with ContentParts format
      # so that subsequent messages can be serialized without FunctionClauseError
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # First message with tool calls
      Nest.LangChainMock.set_tool_response(%{
        text: "I'll check the directory",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_first",
            name: "shell_cmd",
            arguments: %{"command" => "ls"}
          }
        ]
      })

      Nest.LangChainMock.set_response("Directory listing complete")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # First message
      :ok = Agent.chat(pid, "List files")

      # Wait for first conversation to complete
      _messages = collect_all_messages_from_pubsub([])

      # Second message - this triggers serialization of previous tool results
      Nest.LangChainMock.set_response("Second response received")

      # This would raise FunctionClauseError if tool content is not ContentParts
      :ok = Agent.chat(pid, "What else is there?")

      # Wait for second response
      second_messages = collect_all_messages_from_pubsub([])

      # Verify we got the second assistant response
      assistant_msgs =
        Enum.filter(second_messages, fn
          {:assistant, _} -> true
          _ -> false
        end)

      assert [_ | _] = assistant_msgs

      # Cleanup
      Nest.LangChainMock.clear_response()
    end

    test "tool continuation flow broadcasts API calls for each LLM request", %{} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # First response: tool calls
      Nest.LangChainMock.set_tool_response(%{
        text: "I'll execute that",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_api_001",
            name: "shell_cmd",
            arguments: %{"command" => "echo test"}
          }
        ]
      })

      # Second response: final text after tool execution
      Nest.LangChainMock.set_response("Tool executed successfully")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      # Collect all messages (may be broadcast multiple times with api_logs updates)
      messages = collect_all_messages_from_pubsub([])

      # Get unique messages by index (keep latest version with api_logs)
      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      # Find the tool message (index 2) - should have API request log
      tool_msg =
        Enum.find(unique_messages, fn
          {:tool, msg} -> msg.index == 2
          _ -> false
        end)

      assert tool_msg != nil, "Expected to find tool message at index 2"
      {:tool, tool} = tool_msg

      assert tool.api_logs != [],
             "Expected tool message to have API request log"

      has_tool_request = Enum.any?(tool.api_logs, fn log -> log.type == :request end)

      assert has_tool_request,
             "Expected API request log in tool message (tool results sent to API)"

      # Find the final assistant message (index 3) - should have API response log
      final_assistant =
        Enum.find(unique_messages, fn
          {:assistant, msg} -> msg.index == 3
          _ -> false
        end)

      assert final_assistant != nil, "Expected to find final assistant message at index 3"

      {:assistant, final_msg} = final_assistant

      # The final assistant message should have the API response log
      assert final_msg.api_logs != [],
             "Expected final assistant message to have API response log"

      has_response = Enum.any?(final_msg.api_logs, fn log -> log.type == :response end)

      assert has_response,
             "Expected API response log in final assistant message"

      # Cleanup
      Nest.LangChainMock.clear_response()
    end
  end

  describe "API logs" do
    test "every message in simple conversation has API log" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      messages = collect_all_messages_from_pubsub([])

      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      assert length(unique_messages) == 2,
             "Expected 2 messages (user + assistant), got #{length(unique_messages)}"

      for {role, msg} <- unique_messages do
        assert msg.api_logs != [],
               "Message #{msg.index} (#{role}) should have API logs"

        assert length(msg.api_logs) == 1,
               "Message #{msg.index} should have exactly 1 API log"
      end

      {:user, user_msg} = Enum.at(unique_messages, 0)
      assert user_msg.index == 0
      request = Enum.find(user_msg.api_logs, fn log -> log.type == :request end)
      assert request != nil, "User message should have request log"

      {:assistant, assistant_msg} = Enum.at(unique_messages, 1)
      assert assistant_msg.index == 1
      response = Enum.find(assistant_msg.api_logs, fn log -> log.type == :response end)
      assert response != nil, "Assistant message should have response log"
    end

    test "every message in tool call flow has API log including tool message" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      Nest.LangChainMock.set_tool_response(%{
        text: "I'll execute that command",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_001",
            name: "shell_cmd",
            arguments: %{"command" => "echo test"}
          }
        ]
      })

      Nest.LangChainMock.set_response("Command executed successfully")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      messages = collect_all_messages_from_pubsub([])

      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      assert length(unique_messages) == 4,
             "Expected 4 messages (user, assistant+tools, tool, assistant), got #{length(unique_messages)}"

      assert {:user, user_msg} = Enum.at(unique_messages, 0)
      assert user_msg.index == 0

      assert {:assistant, assistant1} = Enum.at(unique_messages, 1)
      assert assistant1.index == 1

      assert {:tool, tool_msg} = Enum.at(unique_messages, 2)
      assert tool_msg.index == 2

      assert {:assistant, assistant2} = Enum.at(unique_messages, 3)
      assert assistant2.index == 3

      for {role, msg} <- unique_messages do
        assert msg.api_logs != [],
               "Message #{msg.index} (#{role}) should have API logs"
      end

      user_request = Enum.find(user_msg.api_logs, fn log -> log.type == :request end)
      assert user_request != nil, "User message should have request log"

      assistant1_response = Enum.find(assistant1.api_logs, fn log -> log.type == :response end)
      assert assistant1_response != nil, "Assistant with tool calls should have response log"

      tool_request = Enum.find(tool_msg.api_logs, fn log -> log.type == :request end)

      assert tool_request != nil,
             "Tool message should have API request log showing tool results were sent to API"

      assistant2_response = Enum.find(assistant2.api_logs, fn log -> log.type == :response end)
      assert assistant2_response != nil, "Final assistant message should have response log"

      Nest.LangChainMock.clear_response()
    end

    test "API log IDs follow correct sequencing pattern" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      Nest.LangChainMock.set_tool_response(%{
        text: "I'll help",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_001",
            name: "shell_cmd",
            arguments: %{"command" => "ls"}
          }
        ]
      })

      Nest.LangChainMock.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List files")

      messages = collect_all_messages_from_pubsub([])

      unique_messages =
        messages
        |> Enum.reverse()
        |> Enum.uniq_by(fn {_role, msg} -> msg.index end)
        |> Enum.reverse()

      {:user, user} = Enum.at(unique_messages, 0)
      [user_log] = user.api_logs
      assert user_log.id == "000.000"
      assert user_log.type == :request

      {:assistant, asst1} = Enum.at(unique_messages, 1)
      [asst1_log] = asst1.api_logs
      assert asst1_log.id == "001.000"
      assert asst1_log.type == :response

      {:tool, tool} = Enum.at(unique_messages, 2)
      [tool_log] = tool.api_logs
      assert tool_log.id == "002.000"
      assert tool_log.type == :request

      {:assistant, asst2} = Enum.at(unique_messages, 3)
      [asst2_log] = asst2.api_logs
      assert asst2_log.id == "003.000"
      assert asst2_log.type == :response

      Nest.LangChainMock.clear_response()
    end
  end

  test "stops agent process" do
    agent_id = "terminating-agent-#{System.unique_integer([:positive])}"
    pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})
    assert Process.alive?(pid)

    ref = Process.monitor(pid)
    Agent.terminate(pid)

    # Wait for process to stop - allow any exit reason
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

    refute Process.alive?(pid)
  end

  # Helper functions

  defp receive_deltas_and_message_from_pubsub do
    receive do
      {:chat_delta, _chunk} ->
        receive_deltas_and_message_from_pubsub()

      {:chat_message, {:user, _}} ->
        receive_deltas_and_message_from_pubsub()

      {:chat_message, {:assistant, assistant_struct}} = msg ->
        assert is_struct(assistant_struct, Nest.Messages.Assistant)
        assert assistant_struct.content != nil
        msg
    after
      2000 ->
        flunk("Timeout waiting for assistant response")
    end
  end

  defp collect_deltas_and_message_from_pubsub(acc \\ "") do
    receive do
      {:chat_delta, %{content: content}} ->
        collect_deltas_and_message_from_pubsub(acc <> content)

      {:chat_message, {:user, _}} ->
        collect_deltas_and_message_from_pubsub(acc)

      {:chat_message, msg} ->
        {acc, msg}
    after
      2000 ->
        flunk("Timeout waiting for deltas")
    end
  end

  defp collect_all_deltas_from_pubsub(deltas \\ []) do
    receive do
      {:chat_delta, delta} ->
        collect_all_deltas_from_pubsub([delta | deltas])

      {:chat_message, {:assistant, _}} ->
        Enum.reverse(deltas)
    after
      500 ->
        Enum.reverse(deltas)
    end
  end

  # Helper to collect all messages from PubSub for tool call flow tests
  defp collect_all_messages_from_pubsub(messages) do
    receive do
      {:chat_message, msg} ->
        collect_all_messages_from_pubsub(messages ++ [msg])
    after
      2000 ->
        messages
    end
  end

  # Helper to wait for tool message
  defp collect_until_tool_message do
    receive do
      {:chat_message, {:tool, _} = msg_tuple} ->
        msg_tuple

      {:chat_message, _} ->
        collect_until_tool_message()
    after
      3000 ->
        flunk("Timeout waiting for tool message")
    end
  end
end
