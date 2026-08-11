defmodule Nest.Agents.AgentObservabilityTest do
  @moduledoc """
  Agent observability tests: API logs, context limit handling, and
  token usage aggregation.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "API logs" do
    test "every message in simple conversation has API log" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Hello")

      # The user message is broadcast twice: first with empty
      # api_logs, then re-broadcast after the LLM call attaches
      # the request log. Match the second broadcast (non-empty
      # api_logs) to capture the externally visible state.
      assert_receive {:chat_message, {:user, %{index: 1, api_logs: [_ | _]} = user_msg}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      assert_receive {:chat_message, {:assistant, %{api_logs: [_ | _]} = assistant_msg}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Run a command")

      assert_receive {:chat_message, {:user, %{index: 1, api_logs: [_ | _]} = user_msg}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      # Indices may shift due to context-notice synthetic pairs;
      # match by content (presence of api_logs).
      assert_receive {:chat_message, {:assistant, %{api_logs: [_ | _]} = assistant1}},
                     500

      assert_receive {:chat_message, {:tool, %{api_logs: [_ | _]} = tool_msg}}, 500
      assert_receive {:chat_delta, _}, 500

      assert_receive {:chat_message, {:assistant, %{api_logs: [_ | _]} = assistant2}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "List files")

      assert_receive {:chat_message, {:user, %{api_logs: [user_log]}}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      # Drain to the first assistant (tool-call). Match by
      # content; the synthetic "Context?" assistant may
      # precede the tool-call assistant.
      asst1 = wait_for_assistant_with_tool(5_000)
      assert asst1 != nil
      [asst1_log] = asst1.api_logs

      tool_msg = wait_for_tool_with_api_logs(5_000)
      assert tool_msg != nil
      [tool_log] = tool_msg.api_logs

      asst2 = wait_for_final_assistant_api_logs(5_000)
      assert asst2 != nil
      [asst2_log] = asst2

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert user_log.id == "001.000"
      assert user_log.type == :request

      # The api_log id is `<message_index>.<sequence>`. With
      # the context-notice synthetic pair, the tool-call
      # assistant is at index 4 instead of 2.
      assert asst1_log.id == "004.000"
      assert asst1_log.type == :response

      # The tool message is at index 5 (one extra for the
      # synthetic pair).
      assert tool_log.id == "005.000"
      assert tool_log.type == :request

      # The final assistant is at index 6.
      assert asst2_log.id == "006.000"
      assert asst2_log.type == :response

      MockClient.clear()
    end
  end

  test "stops agent process" do
    agent_name = "terminating-agent-#{System.unique_integer([:positive])}"
    space_id = AgentTestHelpers.current_space_id()

    pid =
      start_supervised!(
        {Agent,
         %{
           name: agent_name,
           space_id: space_id,
           model: %{name: "qwen3.5-plus"},
           vocation_id: AgentTestHelpers.vocation_id_for_test()
         }}
      )

    ref = Process.monitor(pid)
    Agent.terminate(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  describe "context limit (configured)" do
    test "uses the configured context_limit from DotConfig when present" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      info = Agent.get_public_info(pid)
      assert info.context_limit == 512_000
      assert info.context_limit_source == :config

      Agent.terminate(pid)
    end

    test "does not call Discover when context_limit is already configured" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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
    test "initial usage_totals are all zero except context_input_tokens which reflects the system prompt" do
      # `context_input_tokens` is computed from the messages list
      # (real-valued `tokens` as a floor, estimator for the
      # suffix). For a fresh agent with just a system prompt in
      # messages, it equals the system prompt's estimated size —
      # non-zero. The other usage_totals fields stay at 0 until
      # the first LLM call completes.
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      info = Agent.get_public_info(pid)

      assert info.usage == %{
               input_tokens: 0,
               cache_read_input_tokens: 0,
               cache_creation_input_tokens: 0,
               context_input_tokens: info.usage.context_input_tokens,
               last_output: 0,
               output_tokens: 0,
               total_input_tokens: 0,
               total_cache_read_input_tokens: 0,
               total_cache_creation_input_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0
             }

      assert info.usage.context_input_tokens > 0,
             "expected context_input_tokens > 0 (system prompt estimated size), got #{info.usage.context_input_tokens}"

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "First")
      assert_receive {:chat_status, %{status: "idle"}}, 500

      # usage is exposed via the public API as a GenServer call.
      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 50
      assert info1.usage.input_tokens == 100
      assert info1.usage.last_output == 50

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 500

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Run a command")

      log =
        capture_log(fn ->
          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      info = Agent.get_public_info(pid)
      assert info.usage.output_tokens == 204
      assert info.usage.input_tokens == 1003
      assert info.usage.last_output == 103

      # Empty `arguments_delta: "{}"` triggers the BatchSizer's
      # "Missing required arguments" diagnostic during the
      # incremental stream validation. The test's contract is
      # the accumulated usage; the log is incidental.
      assert log =~ "Missing required arguments: command"

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "First")
      assert_receive {:chat_status, %{status: "idle"}}, 500

      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 25
      assert info1.usage.input_tokens == 50

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 500

      info2 = Agent.get_public_info(pid)
      assert info2.usage.output_tokens == 25
      assert info2.usage.input_tokens == 50
      assert info2.usage.last_output == 25

      Agent.terminate(pid)
    end
  end

  # Drain assistant messages until one carries a `Part.ToolUse`
  # AND has api_logs populated.
  defp wait_for_assistant_with_tool(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_assistant_with_tool(deadline)
  end

  defp do_wait_for_assistant_with_tool(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))
          has_api_logs = msg.api_logs != nil and msg.api_logs != []

          if has_tool_use and has_api_logs do
            msg
          else
            do_wait_for_assistant_with_tool(deadline)
          end
      after
        100 -> do_wait_for_assistant_with_tool(deadline)
      end
    end
  end

  # Drain tool messages until one has api_logs populated.
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

  # Drain assistant messages until we find the final one
  # (no tool_use, with api_logs populated). Returns the api_logs.
  defp wait_for_final_assistant_api_logs(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_final_assistant_api_logs(deadline)
  end

  defp do_wait_for_final_assistant_api_logs(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          has_tool_use = Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))
          has_api_logs = msg.api_logs != nil and msg.api_logs != []

          cond do
            has_tool_use ->
              do_wait_for_final_assistant_api_logs(deadline)

            not has_api_logs ->
              do_wait_for_final_assistant_api_logs(deadline)

            true ->
              msg.api_logs
          end
      after
        100 -> do_wait_for_final_assistant_api_logs(deadline)
      end
    end
  end
end
