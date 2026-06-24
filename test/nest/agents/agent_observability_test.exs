defmodule Nest.Agents.AgentObservabilityTest do
  @moduledoc """
  Agent observability tests: API logs, context limit handling, and
  token usage aggregation.
  """
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
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

  describe "API logs" do
    test "every message in simple conversation has API log" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # The user message is broadcast twice: first with empty
      # api_logs, then re-broadcast after the LLM call attaches
      # the request log. Match the second broadcast (non-empty
      # api_logs) to capture the externally visible state.
      assert_receive {:chat_message, {:user, %{index: 1, api_logs: [_ | _]} = user_msg}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100

      assert_receive {:chat_message,
                      {:assistant, %{index: 2, api_logs: [_ | _]} = assistant_msg}},
                     100

      assert_receive {:chat_status, %{status: "idle"}}, 100

      user_request = Enum.find(user_msg.api_logs, fn log -> log.type == :request end)
      assert user_request != nil, "User message should have request log"

      assistant_response = Enum.find(assistant_msg.api_logs, fn log -> log.type == :response end)
      assert assistant_response != nil, "Assistant message should have response log"
    end

    test "every message in tool call flow has API log including tool message" do
      MockClient.set_tool_response(%{
        text: "I'll execute that command",
        tool_calls: [
          %{id: "call_001", name: "shell_cmd", arguments: %{"command" => "echo test"}}
        ]
      })

      MockClient.set_response("Command executed successfully")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")

      assert_receive {:chat_message, {:user, %{index: 1, api_logs: [_ | _]} = user_msg}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100

      assert_receive {:chat_message, {:assistant, %{index: 2, api_logs: [_ | _]} = assistant1}},
                     100

      assert_receive {:chat_message, {:tool, %{index: 3, api_logs: [_ | _]} = tool_msg}}, 100
      assert_receive {:chat_delta, _}, 100

      assert_receive {:chat_message, {:assistant, %{index: 4, api_logs: [_ | _]} = assistant2}},
                     100

      assert_receive {:chat_status, %{status: "idle"}}, 100

      user_request = Enum.find(user_msg.api_logs, fn log -> log.type == :request end)
      assert user_request != nil, "User message should have request log"

      assistant1_response = Enum.find(assistant1.api_logs, fn log -> log.type == :response end)
      assert assistant1_response != nil, "Assistant with tool calls should have response log"

      tool_request = Enum.find(tool_msg.api_logs, fn log -> log.type == :request end)

      assert tool_request != nil,
             "Tool message should have API request log showing tool results were sent to API"

      assistant2_response = Enum.find(assistant2.api_logs, fn log -> log.type == :response end)
      assert assistant2_response != nil, "Final assistant message should have response log"

      MockClient.clear()
    end

    test "API log IDs follow correct sequencing pattern" do
      MockClient.set_tool_response(%{
        text: "I'll help",
        tool_calls: [
          %{id: "call_001", name: "shell_cmd", arguments: %{"command" => "ls"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "List files")

      assert_receive {:chat_message, {:user, %{index: 1, api_logs: [user_log]}}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100
      assert_receive {:chat_message, {:assistant, %{index: 2, api_logs: [asst1_log]}}}, 100
      assert_receive {:chat_message, {:tool, %{index: 3, api_logs: [tool_log]}}}, 100
      assert_receive {:chat_delta, _}, 100
      assert_receive {:chat_message, {:assistant, %{index: 4, api_logs: [asst2_log]}}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100

      assert user_log.id == "001.000"
      assert user_log.type == :request

      assert asst1_log.id == "002.000"
      assert asst1_log.type == :response

      assert tool_log.id == "003.000"
      assert tool_log.type == :request

      assert asst2_log.id == "004.000"
      assert asst2_log.type == :response

      MockClient.clear()
    end
  end

  test "stops agent process" do
    agent_id = "terminating-agent-#{System.unique_integer([:positive])}"
    pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})

    ref = Process.monitor(pid)
    Agent.terminate(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100
  end

  describe "context limit (configured)" do
    test "uses the configured context_limit from DotConfig when present" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      info = Agent.get_public_info(pid)
      assert info.context_limit == 512_000
      assert info.context_limit_source == :config

      Agent.terminate(pid)
    end

    test "does not call Discover when context_limit is already configured" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # :sys.get_state/1 is a synchronous call — by the time it
      # returns, the GenServer has finished processing any
      # init-time work (including any (incorrectly) spawned probe
      # task). Confirm the configured context_limit is what
      # public_info reports and that the source is :config, not
      # :probe or :default.
      # No broadcast carries the internal context_limit_source field
      # directly; the init push carries it as a wire string. The
      # internal atom is only observable via state — kept as
      # legitimate :sys.get_state use.
      state = :sys.get_state(pid)
      assert state.llm_metrics.context_limit == 512_000
      assert state.llm_metrics.context_limit_source == :config

      Agent.terminate(pid)
    end
  end

  describe "token usage aggregation" do
    test "initial usage_totals are all zero" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      info = Agent.get_public_info(pid)

      assert info.usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0,
               last_output: 0
             }

      Agent.terminate(pid)
    end

    test "accumulates output_tokens across turns" do
      MockClient.set_stream_events([
        {:text, "response 1"},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "response 1", stop_reason: "stop"}}}
      ])

      MockClient.set_stream_events([
        {:text, "response 2"},
        {:usage, %{input_tokens: 200, output_tokens: 100, total_tokens: 300}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "response 2", stop_reason: "stop"}}}
      ])

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First")
      assert_receive {:chat_status, %{status: "idle"}}, 100

      # usage is exposed via the public API as a GenServer call.
      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 50
      assert info1.usage.input_tokens == 100
      assert info1.usage.last_output == 50

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 100

      info2 = Agent.get_public_info(pid)
      assert info2.usage.output_tokens == 150
      assert info2.usage.input_tokens == 200
      assert info2.usage.last_output == 100

      Agent.terminate(pid)
    end

    test "accumulates usage across tool iterations" do
      MockClient.set_stream_events([
        {:text, "Calling tool"},
        {:tool_call_start, %{id: "call_1", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 1001, output_tokens: 101, total_tokens: 1102}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling tool",
             tool_calls: [%ToolCall{id: "call_1", name: "shell_cmd", arguments: %{}}],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_stream_events([
        {:text, "Final answer"},
        {:usage, %{input_tokens: 1003, output_tokens: 103, total_tokens: 1106}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "Final answer", stop_reason: "stop"}}}
      ])

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run a command")
      assert_receive {:chat_status, %{status: "idle"}}, 100

      info = Agent.get_public_info(pid)
      assert info.usage.output_tokens == 204
      assert info.usage.input_tokens == 1003
      assert info.usage.last_output == 103

      Agent.terminate(pid)
    end

    test "nil usage is treated as a no-op" do
      MockClient.set_stream_events([
        {:text, "First"},
        {:usage, %{input_tokens: 50, output_tokens: 25, total_tokens: 75}},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "First", stop_reason: "stop"}}}
      ])

      MockClient.set_stream_events([
        {:text, "Second"},
        {:finish_reason, "stop"},
        {:done, %{response: %RunResponse{text: "Second", stop_reason: "stop"}}}
      ])

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First")
      assert_receive {:chat_status, %{status: "idle"}}, 100

      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 25
      assert info1.usage.input_tokens == 50

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 100

      info2 = Agent.get_public_info(pid)
      assert info2.usage.output_tokens == 25
      assert info2.usage.input_tokens == 50
      assert info2.usage.last_output == 25

      Agent.terminate(pid)
    end
  end
end
