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
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  # Create a Programmer vocation in the test DB and return its id.
  # The "tool budget loop" tests need a vocation with `shell_cmd`
  # registered so the tools actually run; without it, the agent
  # has an empty tool list and every tool call returns
  # "Unknown tool: ...".
  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Test Programmer (#{System.unique_integer([:positive])})",
        description: "A coding assistant that can read and write files in a workspace",
        system_prompt: "Test programmer prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
        modes: %{
          "build" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => true,
              "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
            }
          }
        }
      })

    vocation.id
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

      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id()
        })

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
      # The tool actually ran (we have a Programmer vocation with
      # shell_cmd registered), so the result should be the
      # command's output, not "Unknown tool: ...".
      assert result.content =~ "small"

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
      send(pid, {:compaction_done, new_messages, {:task_compaction_continuation, self()}})

      assert_receive {:chat_compaction, payload}, 100

      assert payload.marker["role"] == "compaction"
      assert payload.marker["archivedCount"] == 4

      # The broadcast history is old_messages ++ [marker]
      assert length(payload.history) == length(old_messages) + 1
      assert match?(%{"role" => "compaction"}, List.last(payload.history))

      # Drain the no-op {:task_compaction_done, _} reply that the
      # continuation clause sends back to the test pid.
      assert_receive {:task_compaction_done, _}, 100

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

  describe "context tool compaction flow" do
    test "context tool with action=compact triggers compaction and returns to idle" do
      # 1st LLM call (chat task): model emits the `context` tool
      # call with `action: "compact"`. The chat task enters
      # `request_compaction_from_task` and blocks on a receive.
      MockClient.set_tool_response(%{
        text: "compacting",
        tool_calls: [
          %{
            id: "call_1",
            name: "context",
            arguments: %{"action" => "compact", "focus" => "recent"}
          }
        ]
      })

      # 2nd LLM call (chat task, after the tool result): the
      # model produces a final text response.
      MockClient.set_response("Done")

      # The compactor's own LLM call (spawned by
      # `CompactionHandler.task_compaction_request/3`) uses a
      # fresh process, so its MockClient lookup misses the
      # agent's queue and falls back to a random text response.
      # That's fine — we only care that the chain completes.

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "compact please")

      # The chat task receives the tool call. The user message
      # is broadcast, the agent transitions to `:streaming`, the
      # text preamble ("compacting") is streamed as a
      # `chat_delta`, then the assistant message with the tool
      # call is broadcast, and the chat task enters
      # `request_compaction_from_task` blocking on a receive.
      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, %{content: "compacting"}}, 500
      assert_receive {:chat_message, {:assistant, %{tool_calls: [%{name: "context"}]}}}, 500
      assert_receive {:chat_status, %{status: "executing_tools"}}, 500

      # The GenServer spawns the compactor, which calls the LLM,
      # gets a random summary, and sends `:compaction_done` back.
      # The GenServer archives the previous messages (broadcasting
      # `chat:compaction`) and sends `:task_compaction_done` to
      # the chat task, which unblocks and returns the
      # "Compacted N messages..." tool result string.
      assert_receive {:chat_compaction, _payload}, 500

      assert_receive {:chat_message, {:tool, %Tool{tool_results: [result]}}}, 1000
      assert result.is_error == false
      assert String.starts_with?(result.content, "Compacted ")

      # The chat task makes a second LLM call (consuming the
      # "Done" response), broadcasts the final text, and the
      # agent transitions to idle.
      assert_receive {:chat_delta, %{content: "Done"}}, 1000
      assert_receive {:chat_message, {:assistant, _}}, 1000
      assert_receive {:chat_status, %{status: "idle"}}, 1000

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

      send(pid, {:compaction_done, new_messages, {:task_compaction_continuation, self()}})

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
