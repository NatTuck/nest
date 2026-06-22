defmodule Nest.Agents.AgentCompactionTest do
  @moduledoc """
  Agent compaction and pre-flight tests: tool budget loop,
  compaction history, pre-flight streaming guard, and
  `chat:compaction` broadcast.
  """
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Streaming
  alias Nest.Messages.Tool
  alias Nest.Messages.User
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

  describe "tool budget loop" do
    test "small tool results pass through unchanged" do
      MockClient.set_tool_response(%{
        text: "Reading file",
        tool_calls: [
          %{id: "call_1", name: "shell_cmd", arguments: %{"command" => "echo small"}}
        ]
      })

      MockClient.set_response("Done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Read a file")

      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, %{content: "Reading file"}}, 100
      assert_receive {:chat_message, {:tool, %Tool{tool_results: [result]}}}, 100
      assert_receive {:chat_delta, %{content: "Done"}}, 100
      assert_receive {:chat_message, {:assistant, _}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100

      refute String.contains?(result.content, "[truncated:")
      refute String.contains?(result.content, "[skipped:")
      assert result.is_error == false

      Agent.terminate(pid)
    end

    test "order is preserved when multiple tool calls are returned" do
      MockClient.set_stream_events([
        {:text, "Running two commands"},
        {:tool_call_start, %{id: "call_1", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_1", arguments_delta: "{}"}},
        {:tool_call_start, %{id: "call_2", name: "shell_cmd"}},
        {:tool_call_delta, %{id: "call_2", arguments_delta: "{}"}},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "tool_calls"},
        {:done,
         %{
           response: %RunResponse{
             text: "Running two commands",
             tool_calls: [
               %Nest.Messages.ToolCall{
                 id: "call_1",
                 name: "shell_cmd",
                 arguments: %{"command" => "echo first"}
               },
               %Nest.Messages.ToolCall{
                 id: "call_2",
                 name: "shell_cmd",
                 arguments: %{"command" => "echo second"}
               }
             ],
             stop_reason: "tool_calls"
           }
         }}
      ])

      MockClient.set_response("All done")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Run two")

      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, %{content: "Running two commands"}}, 100
      assert_receive {:chat_message, {:tool, %Tool{tool_results: results}}}, 100
      assert_receive {:chat_delta, %{content: "All done"}}, 100
      assert_receive {:chat_message, {:assistant, _}}, 100
      assert_receive {:chat_status, %{status: "idle"}}, 100

      assert length(results) == 2
      assert Enum.map(results, & &1.tool_call_id) == ["call_1", "call_2"]

      Agent.terminate(pid)
    end
  end

  describe "compaction history" do
    test "compaction_done archives previous messages to history with a marker" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      old_messages = [
        {:user, %User{index: 0, content: "First", api_logs: []}},
        {:assistant, %Assistant{index: 1, content: "A1", api_logs: []}},
        {:user, %User{index: 2, content: "Second", api_logs: []}},
        {:assistant, %Assistant{index: 3, content: "A2", api_logs: []}}
      ]

      new_messages = [
        {:system,
         %Nest.Messages.System{index: 4, content: "[Summary of earlier conversation]:\n\n..."}},
        {:user, %User{index: 5, content: "Third", api_logs: []}}
      ]

      :sys.replace_state(pid, fn s ->
        %{s | chat_state: %{s.chat_state | messages: old_messages}}
      end)

      # The compaction handler broadcasts a `chat:compaction` event
      # whose `history` field is the externally visible representation
      # of `state.history` after archiving. We assert on that
      # broadcast instead of reading internal state.
      send(pid, {:compaction_done, new_messages, {:compact_context_continuation, self()}})

      assert_receive {:chat_compaction, payload}, 100

      assert payload.marker["role"] == "compaction"
      assert payload.marker["archivedCount"] == 4

      # The broadcast history is old_messages ++ [marker]
      assert length(payload.history) == length(old_messages) + 1
      assert match?(%{"role" => "compaction"}, List.last(payload.history))

      # Drain the no-op {:compact_context_done, _} reply that the
      # continuation clause sends back to the test pid.
      assert_receive {:compact_context_done, _}, 100

      Agent.terminate(pid)
    end
  end

  describe "pre-flight streaming guard" do
    test "preflight_request with active streaming returns :proceed without compacting" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :sys.replace_state(pid, fn s ->
        acc = Streaming.new(s.chat_state.next_message_index)
        acc = %{acc | text_buffer: "partial response..."}
        %{s | chat_state: %{s.chat_state | streaming_acc: acc}}
      end)

      state_before = :sys.get_state(pid)
      msg_count = length(state_before.chat_state.messages || [])

      fake_task = self()
      send(pid, {:preflight_request, fake_task, state_before.chat_state.messages || []})

      # Known reply from the preflight handler.
      assert_receive {:preflight_result, :proceed, _}, 100

      # The preflight handler does not broadcast anything; the only
      # externally visible signal is the {:preflight_result, ...} reply
      # above. To verify "didn't touch state.messages" we have to
      # inspect state — kept as a legitimate :sys.get_state use.
      state_after = :sys.get_state(pid)
      assert length(state_after.chat_state.messages || []) == msg_count

      Agent.terminate(pid)
    end

    test "preflight_request with empty streaming_acc and fits returns :proceed" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      state_before = :sys.get_state(pid)
      assert state_before.chat_state.streaming_acc == nil

      send(pid, {:preflight_request, self(), state_before.chat_state.messages || []})

      assert_receive {:preflight_result, :proceed, _}, 100

      Agent.terminate(pid)
    end
  end

  describe "chat:compaction broadcast" do
    test "compaction_done broadcasts chat:compaction with marker and history" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      old_messages = [
        {:user, %User{index: 0, content: "First", api_logs: []}},
        {:assistant, %Assistant{index: 1, content: "A1", api_logs: []}}
      ]

      new_messages = [
        {:system,
         %Nest.Messages.System{index: 2, content: "[Summary of earlier conversation]:\n\n..."}},
        {:user, %User{index: 3, content: "Next", api_logs: []}}
      ]

      :sys.replace_state(pid, fn s ->
        %{s | chat_state: %{s.chat_state | messages: old_messages, next_message_index: 2}}
      end)

      send(pid, {:compaction_done, new_messages, {:compact_context_continuation, self()}})

      assert_receive {:chat_compaction, payload}, 100

      assert payload.marker["role"] == "compaction"
      assert payload.marker["archivedCount"] == 2
      assert payload.marker["index"] == 2
      assert is_list(payload.history)
      assert length(payload.history) == 3
      assert match?(%{"role" => "compaction"}, List.last(payload.history))

      Agent.terminate(pid)
    end
  end
end
