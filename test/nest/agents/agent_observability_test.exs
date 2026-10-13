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
    test "user message has empty api_logs; assistant message carries response log from successful API call" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Hello")

      # User messages no longer carry request api_logs after finalization
      # (they're rebuilt on demand when the user expands the API logs widget).
      assert_receive {:chat_message, {:user, %{api_logs: user_api_logs}}}, 1_000
      assert user_api_logs == [], "User message should have empty api_logs"

      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      assert_receive {:chat_delta, _}, 1_000

      # The assistant message is stored complete: the response log is
      # attached before it is appended, so the single broadcast carries it.
      assert_receive {:chat_message, {:assistant, %{api_logs: [assistant_response]}}}, 1_000
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      assert assistant_response.type == :response, "Assistant message should have response log"

      refute Map.has_key?(assistant_response.payload, :messages),
             "response log payload must not contain the request message history"
    end

    test "assistant response log is persisted with the message and survives a reload" do
      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Hello")
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # Read back through the DB, not the live agent, to prove the
      # response log was stored with the message rather than only
      # living in memory.
      persisted = Nest.Persistence.load_messages(AgentTestHelpers.current_space_id(), agent_id)

      {:assistant, %{api_logs: [log]}} = Enum.find(persisted, &match?({:assistant, _}, &1))

      assert log.type == :response
      assert is_map(log.payload)
      refute Map.has_key?(log.payload, "messages")
    end

    test "assistant messages carry response API logs; user and tool messages have empty api_logs" do
      MockClient.set_tool_response(%{
        text: "I'll execute that command",
        tool_calls: [
          %{id: "call_001", name: "shell-cmd", arguments: %{"command" => "echo test"}}
        ]
      })

      MockClient.set_response("Command executed successfully")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Run a command")

      assert_receive {:chat_message, {:user, %{api_logs: user_api_logs}}}, 1_000
      assert user_api_logs == [], "User message should have empty api_logs"

      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      assert_receive {:chat_delta, _}, 1_000

      # The tool-call assistant is stored complete with its response log.
      assert_receive {:chat_message, {:assistant, %{api_logs: [asst1_log]}}}, 1_000
      assert asst1_log.type == :response

      assert_receive {:chat_message, {:tool, %{api_logs: tool_api_logs}}}, 1_000
      assert tool_api_logs == [], "Tool message should have empty api_logs"

      # The turn's end is the fence: the `idle` frame is emitted after the
      # turn's last append, so the final assistant's response log is then
      # readable from the transcript.
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      asst2 = final_assistant_api_logs(chat_messages(pid))
      assert asst2 != nil
      [asst2_log] = asst2

      assert asst2_log.type == :response, "Final assistant message should have response log"

      MockClient.clear()
    end

    test "assistant messages carry correctly sequenced response API logs" do
      MockClient.set_tool_response(%{
        text: "I'll help",
        tool_calls: [
          %{id: "call_001", name: "shell-cmd", arguments: %{"command" => "ls"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "List files")

      assert_receive {:chat_message, {:user, %{api_logs: user_api_logs}}}, 1_000
      assert user_api_logs == [], "User message should have empty api_logs"

      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      assert_receive {:chat_delta, _}, 1_000

      # The turn's end is the fence: the `idle` frame is emitted after the
      # turn's last append, so the whole turn is then readable from the
      # transcript. Match by content; the synthetic "Context?" assistant may
      # precede the tool-call assistant.
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      messages = chat_messages(pid)

      asst1 = assistant_with_tool(messages)
      assert asst1 != nil
      [asst1_log] = asst1.api_logs

      assert_receive {:chat_message, {:tool, %{api_logs: tool_api_logs}}}, 1_000
      assert tool_api_logs == [], "Tool message should have empty api_logs"

      asst2 = final_assistant_api_logs(messages)
      assert asst2 != nil
      [asst2_log] = asst2

      # The api_log id is `<message_index>.<sequence>`. At this low
      # usage no context-notice pair fires, so the tool-call
      # assistant keeps index 2. (The synthetic-pair index shift is
      # covered by `agent_system_messages_test.exs`, which forces a
      # real threshold crossing.)
      assert asst1_log.id == "002.000"
      assert asst1_log.type == :response

      # The final assistant is at index 4.
      assert asst2_log.id == "004.000"
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

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
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
      state = :sys.get_state(pid, 1_000)
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
               working_budget: 409_600,
               projected_context_input_tokens: nil,
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
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # usage is exposed via the public API as a GenServer call.
      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 50
      assert info1.usage.input_tokens == 100
      assert info1.usage.last_output == 50

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      info2 = Agent.get_public_info(pid)
      assert info2.usage.output_tokens == 150
      assert info2.usage.input_tokens == 200
      assert info2.usage.last_output == 100

      Agent.terminate(pid)
    end

    test "accumulates usage across tool iterations" do
      MockClient.set_stream_events([
        {:text, "Calling tool"},
        {:tool_call_start, %{id: "call_1", name: "shell-cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 1001, output_tokens: 101, total_tokens: 1102}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Calling tool",
             tool_calls: [%ToolCall{id: "call_1", name: "shell-cmd", arguments: %{}}],
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

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Run a command")
          assert_receive {:chat_status, %{status: "idle"}}, 1_000
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
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      info1 = Agent.get_public_info(pid)
      assert info1.usage.output_tokens == 25
      assert info1.usage.input_tokens == 50

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      info2 = Agent.get_public_info(pid)
      assert info2.usage.output_tokens == 25
      assert info2.usage.input_tokens == 50
      assert info2.usage.last_output == 25

      Agent.terminate(pid)
    end
  end

  # The turn's transcript, read synchronously. `MessageAppender.append_stamped/2`
  # appends each message before the settle loop broadcasts the `idle` status, so
  # once the turn's `idle` frame has arrived the whole turn is readable from the
  # state: every message of the turn is already appended, whether or not this
  # process happened to receive that message's own frame.
  defp chat_messages(pid), do: Agent.get_messages(pid)

  # The first assistant in `messages` that carries a `Part.ToolUse` AND has
  # api_logs populated; nil when there is none.
  defp assistant_with_tool(messages) do
    Enum.find_value(messages, fn
      {:assistant, msg} ->
        if has_tool_use?(msg) and has_api_logs?(msg), do: msg

      _other ->
        nil
    end)
  end

  # The api_logs of the final assistant in `messages`: the first assistant
  # with no `Part.ToolUse` of its own that has api_logs populated; nil when
  # the turn recorded none.
  defp final_assistant_api_logs(messages) do
    Enum.find_value(messages, fn
      {:assistant, msg} ->
        if not has_tool_use?(msg) and has_api_logs?(msg), do: msg.api_logs

      _other ->
        nil
    end)
  end

  defp has_tool_use?(msg), do: Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1))

  defp has_api_logs?(msg), do: msg.api_logs != nil and msg.api_logs != []
end
