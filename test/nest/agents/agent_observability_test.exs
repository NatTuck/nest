defmodule Nest.Agents.AgentObservabilityTest do
  @moduledoc """
  Agent observability tests: response API-log persistence and token
  usage aggregation.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.ToolCall

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "API logs" do
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
      refute Map.has_key?(log.payload, "messages")
    end
  end

  describe "token usage aggregation" do
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
end
