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

      send(pid, {:compaction_done, new_messages, {:task_compaction_continuation, self()}})

      # `:sys.get_state/1` queues behind `:compaction_done` and
      # returns only after the broadcast has fired (broadcast is
      # in the same callback as the message handling), so the
      # PubSub message is already in our mailbox.
      _ = :sys.get_state(pid)

      assert_receive {:chat_compaction, payload}
      assert payload.marker["role"] == "compaction"
      assert payload.marker["archivedCount"] == 4
      assert length(payload.history) == length(old_messages) + 1
      assert match?(%{"role" => "compaction"}, List.last(payload.history))

      # Drain the no-op {:task_compaction_done, _} reply that the
      # continuation clause sends back to the test pid.
      assert_receive {:task_compaction_done, _}

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
      # The chat task's first LLM call returns the
      # `context.compact` tool call. The task enters
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

      # The chat task's second LLM call (after the compactor
      # returns) consumes this final response.
      MockClient.set_response("Done")

      # The compactor's own LLM call (spawned by
      # `CompactionHandler.task_compaction_request/3`) runs in
      # a fresh Task whose `MockClient.run/2` lookup misses the
      # agent's queue (the run opts don't thread `agent_pid`
      # through). The call falls back to a random text summary,
      # which is fine for this test — we assert on the final
      # post-compaction shape, not on the compactor's text.

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "compact please")

      # Single deterministic fence: the chain has finished.
      # `:chat_status "idle"` is broadcast exactly once at the
      # end of the chat turn, no matter how many internal
      # iterations happen. Reading intermediate broadcasts
      # before this races on the BEAM scheduler.
      assert_receive {:chat_status, %{status: "idle"}}, 5_000

      # Now the agent is fully done. Read final state from the
      # GenServer, not from the broadcast stream.
      state = :sys.get_state(pid)
      messages = state.chat_state.messages
      history = state.chat_state.history

      # Post-compaction shape (the compactor's `swap_messages/3`
      # archived the original [system, user, assistant] chunk
      # into `history`, then regenerated and put the new
      # [system, summary_user] into `messages`, and the chat
      # task's tool worker produced the `:tool` message
      # followed by a final `:assistant` for "Done"):
      #
      #   messages = [system, system, tool, assistant]
      #   history = [system, user, assistant, compaction]
      #
      # Index positions vary — we assert by role + content.

      # The regenerated system message landed in messages.
      assert Enum.any?(messages, &match?({:system, _}, &1)),
             "expected a regenerated system message in the active chat"

      # The chat task's tool result for `context.compact` is what
      # `CompactionHandler.task_compaction_done/3` synthesizes —
      # a "Compacted N messages..." text carrying the compaction
      # status. Assert on the persisted state, not on broadcast.
      compacted_tool_result =
        Enum.find_value(messages, fn
          {:tool, %{parts: [%Part.ToolResult{name: "context", content: c} | _]}} -> c
          _ -> nil
        end)

      assert compacted_tool_result,
             "expected the chat task's :tool message for context.compact with content"

      assert String.starts_with?(compacted_tool_result, "Compacted ")

      # Final assistant message came back from the chat task's
      # second LLM call (the "Done" MockClient response).
      assert Enum.any?(messages, &match?({:assistant, _}, &1)),
             "expected a final assistant message in the active chat"

      # The compaction marker is in history with archived_count > 0.
      assert Enum.any?(history, fn
               {:compaction, %{archived_count: n}} when n > 0 -> true
               _ -> false
             end),
             "expected the chat:compaction marker in history with archived_count > 0"

      # The trigger user message ("compact please") ended up in
      # history because the compactor archived it during the swap.
      assert Enum.any?(history, &match?({:user, _}, &1)),
             "expected the trigger user message archived into history"

      Agent.terminate(pid)
    end
  end

  describe "context_overflow preflight (cannot_compact)" do
    test "system + first user message exceeds limit → status :context_overflow, no compaction, error broadcast" do
      # The realistic API-log scenario: a moderate system prompt
      # (~8400 estimated tokens) plus a small user message plus
      # the 8192-token reserve already overflow the configured
      # 10k context_limit. Compaction would be a no-op (the
      # compactor returns :too_short for `[system, user]` with
      # an empty head), so the chat pipeline must refuse the
      # user's request: clear `pending_user_message`, set
      # `:context_overflow` status, broadcast a `chat:error`
      # with the actual numbers, and stay idle. No chat turn
      # is spawned.
      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id()
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # Drop the agent's context_limit to 10k so the test
      # matches the API log scenario. The default for
      # qwen3.5-plus is much larger, so the system prompt
      # would otherwise fit.
      :sys.replace_state(pid, fn s ->
        %{s | llm_metrics: %{s.llm_metrics | context_limit: 10_000}}
      end)

      # And inflate the system prompt so the projected total
      # (system + user + 8192 reserve) exceeds 10k even after
      # the empty-head compaction short-circuit.
      :sys.replace_state(pid, fn s ->
        [{:system, sys_struct} | rest] = s.chat_state.messages

        inflated_system =
          {:system, %{sys_struct | parts: [%Part.Text{text: String.duplicate("z", 7_000)}]}}

        %{s | chat_state: %{s.chat_state | messages: [inflated_system | rest]}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Agent.chat(pid, "What do we need to do?")

          # The chat pipeline detects `:cannot_compact` and sets
          # the new status, broadcasts the error with the actual
          # numbers, and does NOT spawn a chat turn.
          assert_receive {:chat_status, %{status: "context_overflow"}}, 500

          # The chat:error is broadcast with `compactionError`
          # NOT set (so the JS routes it to `setAgentError`,
          # not `setCompactionError`) and carries the actual
          # numbers (limit, system prompt size, reserve).
          assert_receive {:chat_error, payload}, 500
          refute Map.get(payload, :compactionError) == true
          assert payload.content =~ "context limit (10000)"
          assert payload.content =~ "system prompt"
          assert payload.content =~ "reserved response budget (8192 tokens)"
        end)

      # The handler logs at info or warning level for debugging.
      assert log =~ "context_overflow" or log =~ "context limit"

      # The agent stays idle (no chat turn was spawned).
      state_after = :sys.get_state(pid)
      assert state_after.chat_state.status == :context_overflow
      assert state_after.chat_state.pending_user_message == nil

      # The user message was NOT appended to the conversation.
      assert length(state_after.chat_state.messages) == 1
      assert match?({:system, _}, hd(state_after.chat_state.messages))

      Agent.terminate(pid)
    end

    test "first user message within limit → chat turn spawned, no overflow" do
      # Regression guard: when the conversation actually fits,
      # the preflight returns `:fits` and the chat turn proceeds
      # normally. We use a generous context_limit (128k) so the
      # default system prompt + user message + reserve all fit.
      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id()
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      MockClient.set_response("Hello back")

      Agent.chat(pid, "Hello")

      # The user message is broadcast, the chat turn starts,
      # and the LLM responds. No context_overflow status.
      assert_receive {:chat_message, {:user, _}}, 500
      refute_receive {:chat_status, %{status: "context_overflow"}}, 200

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

      _ = :sys.get_state(pid)

      assert_receive {:chat_compaction, payload}

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
