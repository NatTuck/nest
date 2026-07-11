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

  # Build a `{:assistant, %Assistant{}}` with a single
  # `%Part.ToolUse{name: "context"}` at index `idx`. Tests use
  # this when they need a carried tool_use without pre-seeding
  # `state.chat_state.messages` via `:sys.replace_state`.
  defp compact_tool_call_msg(idx) do
    {:assistant,
     %Assistant{
       index: idx,
       parts: [
         %Part.ToolUse{
           id: "c1",
           name: "context",
           arguments: %{"action" => "compact"}
         }
       ],
       api_logs: []
     }}
  end

  # Create a Programmer vocation in the test DB and return its id.
  # The "tool budget loop" tests need `shell_cmd` registered; without
  # it, the agent has an empty tool list and every call returns
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

      # The compactor LLM's response text. The regenerator wraps
      # it as "Summary of earlier conversation:\n\n…".
      summary_text = "..."

      # `:tool_call` continuation; spawn ChatTurn sits idle waiting
      # for `:tool_results` — we only care about the broadcast.
      tool_call_msg = compact_tool_call_msg(3)

      :sys.replace_state(pid, fn s ->
        %{s | chat_state: %{s.chat_state | messages: old_messages}}
      end)

      send(pid, {:compaction_done, summary_text, {:tool_call, tool_call_msg, 3, 30}})

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
      # First LLM call emits the context.compact tool call.
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

      # Second LLM call (after compaction) consumes this.
      MockClient.set_response("Done")

      # The compactor's LLM call doesn't thread `agent_pid` through
      # so it falls back to a random text summary. We assert on
      # the final post-compaction shape, not on the compactor's text.

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "compact please")

      # Single deterministic fence: `:chat_status "idle"` fires once
      # at the end. Read intermediate broadcasts races the BEAM
      # scheduler.
      assert_receive {:chat_status, %{status: "idle"}}, 5_000

      state = :sys.get_state(pid)
      messages = state.chat_state.messages
      history = state.chat_state.history

      # Post-compaction shape: original [system, user, assistant] +
      # compaction marker in history; new [fresh_system,
      # summary_user, carried_tool_call, synthetic_tool_result]
      # plus the chat turn's final LLM "Done" assistant in
      # messages. Index positions vary; assert by role + content.

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
             "expected :tool message for context.compact with content"

      assert String.starts_with?(compacted_tool_result, "Compacted ")

      # Final assistant message from the chat turn's second LLM call.
      assert Enum.any?(messages, &match?({:assistant, _}, &1)),
             "expected a final assistant message in the active chat"

      # Compaction marker in history.
      assert Enum.any?(history, fn
               {:compaction, %{archived_count: n}} when n > 0 -> true
               _ -> false
             end),
             "expected chat:compaction marker in history with archived_count > 0"

      # Trigger user message archived during the swap.
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

      summary_text = "..."

      # `:tool_call` continuation with a carried tool_use at the tail.
      tool_call_msg = compact_tool_call_msg(1)

      :sys.replace_state(pid, fn s ->
        %{s | chat_state: %{s.chat_state | messages: old_messages, next_message_index: 2}}
      end)

      send(pid, {:compaction_done, summary_text, {:tool_call, tool_call_msg, 3, 30}})

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
