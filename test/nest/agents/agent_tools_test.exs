defmodule Nest.Agents.AgentToolsTest do
  @moduledoc """
  Agent tool execution tests: `chat/2` with tool calls and
  `configured_max_tool_iterations/0`.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Test.TaskDrain

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List the files")

      # User message: first broadcast is empty, second carries the
      # request log. Match the second (non-empty api_logs).
      assert_receive {:chat_message,
                      {:user, %{index: 0, content: "[mode: chat]\nList the files"}}},
                     100

      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100

      assert_receive {:chat_message,
                      {:assistant,
                       %{
                         index: 1,
                         content: "I'll run that command for you",
                         tool_calls: [tool_call]
                       }}},
                     100

      assert_receive {:chat_status, %{status: "executing_tools"}}, 100
      assert_receive {:chat_message, {:tool, %{index: 2, tool_results: [tool_result]}}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100

      assert_receive {:chat_message,
                      {:assistant, %{index: 3, content: "Here are the directory contents"}}},
                     100

      assert_receive {:chat_status, %{status: "idle"}}, 100

      assert %ToolCall{} = tool_call
      assert tool_call.id == "call_123"
      assert tool_call.name == "shell_cmd"

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      # Each transition is a known broadcast in known order.
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_status, %{status: "executing_tools"}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "What is 2+2?")

      assert_receive {:chat_message, {:user, _}}, 100

      assert_receive {:chat_message,
                      {:assistant,
                       %{index: 1, content: "Let me calculate that", tool_calls: [tool_call]}}},
                     100

      assert_receive {:chat_status, %{status: "idle"}}, 100

      assert tool_call.name == "calculator"
      assert tool_call.arguments == %{"expression" => "2 + 2"}

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "What's the weather?")

      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_message, {:tool, %Tool{index: 2, tool_results: tool_results}}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List files")
      assert_receive {:chat_status, %{status: "idle"}}, 100

      MockClient.set_response("Second response received")

      :ok = Agent.chat(pid, "What else is there?")
      # Second turn: new user message (index 4) + assistant response (index 5).
      assert_receive {:chat_message,
                      {:user, %{index: 4, content: "[mode: chat]\nWhat else is there?"}}},
                     100

      assert_receive {:chat_message,
                      {:assistant, %{index: 5, content: "Second response received"}}},
                     100

      assert_receive {:chat_status, %{status: "idle"}}, 100

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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      # The tool message is re-broadcast after its api_logs are
      # populated. Match the version with at least one request log.
      assert_receive {:chat_message, {:tool, %{index: 2, api_logs: [_ | _] = tool_logs}}}, 100

      assert_receive {:chat_message, {:assistant, %{index: 3, api_logs: [_ | _] = final_logs}}},
                     100

      assert_receive {:chat_status, %{status: "idle"}}, 100

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
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("I've completed the task after multiple iterations")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      capture_log(fn ->
        :ok = Agent.chat(pid, "Keep looping")

        assert_receive {:chat_notification,
                        %{type: "max_iterations", message: "Max tool iterations reached"}},
                       3000

        # The final assistant response is the one carrying the
        # "I've completed..." content. The chat_status idle arrives
        # after that.
        assert_receive {:chat_message,
                        {:assistant,
                         %{content: "I've completed the task after multiple iterations"}}},
                       1000

        assert_receive {:chat_status, %{status: "idle"}}, 1000

        refute_receive {:chat_error, _}, 100
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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Brief loop")

      assert_receive {:chat_status, %{status: "idle"}}, 100
      refute_receive {:chat_notification, %{type: "max_iterations"}}, 100

      MockClient.clear()
    end
  end

  describe "configured_max_tool_iterations/0" do
    test "returns the configured value when DotConfig has one" do
      Mimic.stub(Nest.DotConfig, :load, fn ->
        {:ok, %{providers: %{}, models: %{}, max_tool_iterations: 7}}
      end)

      assert Agent.configured_max_tool_iterations() == 7
    end

    test "returns the hardcoded default of 99 when DotConfig has no max_tool_iterations" do
      Mimic.stub(Nest.DotConfig, :load, fn ->
        {:ok, %{providers: %{}, models: %{}, max_tool_iterations: nil}}
      end)

      assert Agent.configured_max_tool_iterations() == 99
    end

    test "returns the hardcoded default of 99 when DotConfig.load/0 returns an error" do
      Mimic.stub(Nest.DotConfig, :load, fn -> {:error, "no config file"} end)

      assert Agent.configured_max_tool_iterations() == 99
    end
  end
end
