defmodule Nest.Agents.AgentCompactionTest do
  @moduledoc """
  Agent compaction and pre-flight tests: tool budget loop,
  compaction history, pre-flight streaming guard,
  `chat:compaction` broadcast, and system prompt regeneration
  on compaction (the on-demand-load fix — see
  `notes/update-system-msg-on-compaction.md`).
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
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
        name: "Test Programmer (#{Elixir.System.unique_integer([:positive])})",
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

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_message, {:user, _}}
      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_delta, %{content: "Reading file"}}
      assert_received {:chat_message, {:tool, %Tool{parts: [result_part | _]}}}
      assert_received {:chat_delta, %{content: "Done"}}
      assert_received {:chat_message, {:assistant, _}}

      %Part.ToolResult{content: content, is_error: is_error} = result_part
      refute String.contains?(content, "[truncated:")
      refute String.contains?(content, "[skipped:")
      assert is_error == false
      # The tool actually ran (we have a Programmer vocation with
      # shell_cmd registered), so the result should be the
      # command's output, not "Unknown tool: ...".
      assert content =~ "small"

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

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_message, {:user, _}}
      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_delta, %{content: "Running two commands"}}
      assert_received {:chat_message, {:tool, %Tool{parts: parts}}}
      assert_received {:chat_delta, %{content: "All done"}}
      assert_received {:chat_message, {:assistant, _}}

      assert length(parts) == 2
      assert Enum.map(parts, & &1.tool_call_id) == ["call_1", "call_2"]

      Agent.terminate(pid)
    end
  end

  describe "compaction history" do
    test "compaction_done archives previous messages to history with a marker" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      old_messages = [
        {:user, %User{index: 0, parts: [%Part.Text{text: "First"}], api_logs: []}},
        {:assistant, %Assistant{index: 1, parts: [%Part.Text{text: "A1"}], api_logs: []}},
        {:user, %User{index: 2, parts: [%Part.Text{text: "Second"}], api_logs: []}},
        {:assistant, %Assistant{index: 3, parts: [%Part.Text{text: "A2"}], api_logs: []}}
      ]

      new_messages = [
        {:system,
         %Nest.Messages.System{
           index: 4,
           parts: [%Part.Text{text: "[Summary of earlier conversation]:\n\n..."}]
         }},
        {:user, %User{index: 5, parts: [%Part.Text{text: "Third"}], api_logs: []}}
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

  describe "per-iteration preflight has been removed" do
    test "CompactionHandler does not accept {:preflight_request, _, _} (Trigger A is gone)" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Per-iteration preflight compaction was removed in favor of
      # the BatchSizer + Trigger B (per-handle_chat). The Agent
      # must NOT have a handler for `{:preflight_request, _, _}` —
      # any such message lands in the Agent's mailbox unhandled
      # and is silently discarded.
      state_before = :sys.get_state(pid)
      fake_task = self()

      send(pid, {:preflight_request, fake_task, state_before.chat_state.messages || []})

      # Wait briefly to ensure the Agent (if it had a handler) would have
      # processed the message and replied. There should be NO
      # `:preflight_result` reply.
      refute_receive {:preflight_result, _, _}, 200

      Agent.terminate(pid)
    end

    test "CompactionHandler does not accept {:compaction_failed_for_preflight, _, _}" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      fake_task = self()

      send(pid, {:compaction_failed_for_preflight, fake_task, :llm_returned_empty})

      refute_receive {:preflight_result, _, _}, 200

      Agent.terminate(pid)
    end

    test "streaming_acc is no longer consulted by any preflight path" do
      # The legacy design had a `streaming_active?` shortcut that
      # returned `:proceed` while the LLM was still streaming the
      # response. That shortcut is forbidden under our constraint
      # ("never send an LLM request whose message list predictably
      # overflows"). Streaming_acc still exists — the BatchSizer
      # waits for the assistant message to be finalized before
      # running — but no preflight handler reads it.
      #
      # Structural assertion: the CompactionHandler has no path
      # that consults `streaming_acc`.
      handler = File.read!("lib/nest/agents/agent/handlers/compaction_handler.ex")

      refute handler =~ "streaming_acc",
             "CompactionHandler must not consult streaming_acc " <>
               "(forbidden under the never-overflow constraint)"
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

      assert_receive {:chat_message,
                      {:assistant, %{parts: [_text, %Part.ToolUse{name: "context"} | _]}}},
                     500

      assert_receive {:chat_status, %{status: "executing_tools"}}, 500

      # The GenServer spawns the compactor, which calls the LLM,
      # gets a random summary, and sends `:compaction_done` back.
      # The GenServer archives the previous messages (broadcasting
      # `chat:compaction`) and sends `:task_compaction_done` to
      # the chat task, which unblocks and returns the
      # "Compacted N messages..." tool result string.
      assert_receive {:chat_compaction, _payload}, 500

      assert_receive {:chat_message, {:tool, %Tool{parts: [result_part | _]}}}, 1000
      %Part.ToolResult{content: content, is_error: is_error} = result_part
      assert is_error == false
      assert String.starts_with?(content, "Compacted ")

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
        {:user, %User{index: 0, parts: [%Part.Text{text: "First"}], api_logs: []}},
        {:assistant, %Assistant{index: 1, parts: [%Part.Text{text: "A1"}], api_logs: []}}
      ]

      new_messages = [
        {:system,
         %Nest.Messages.System{
           index: 2,
           parts: [%Part.Text{text: "[Summary of earlier conversation]:\n\n..."}]
         }},
        {:user, %User{index: 3, parts: [%Part.Text{text: "Next"}], api_logs: []}}
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
