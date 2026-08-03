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
  alias Nest.Persistence
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
  # `programmer_vocation_id_for_test/0` lives in `AgentTestHelpers`
  # (promoted from a local `defp` for cross-file reuse). Tests
  # that exercise the tool-call flow pass it as `vocation_id:`
  # to `start_agent/1` so `shell_cmd` (and the file tools) are
  # actually registered; otherwise BatchSizer returns
  # "Unknown tool: shell_cmd" for every call.
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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

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
      # Structural assertion: the Compaction.ResultHandler has no
      # path that consults `streaming_acc`.
      handler = File.read!("lib/nest/agents/agent/compaction/result_handler.ex")

      refute handler =~ "streaming_acc",
             "Compaction.ResultHandler must not consult streaming_acc " <>
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

      # Use a real Programmer vocation so the compaction
      # re-renders the system prompt (proving the
      # `compose_vocation_config/4` path runs). Tests
      # without a real vocation also pass — the
      # re-rendered system is just absent — but this
      # exercises the full code path.
      voc_id = programmer_vocation_id_for_test()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: voc_id,
          vocation: Persistence.load_vocation(voc_id)
        })

      :ok = Agent.chat(pid, "compact please")

      # Single deterministic fence: `:chat_status "idle"` fires once
      # at the end. Read intermediate broadcasts races the BEAM
      # scheduler.
      assert_receive {:chat_status, %{status: "idle"}}, 5_000

      state = :sys.get_state(pid)
      messages = state.chat_state.messages
      history = state.chat_state.history

      # Post-compaction shape (compactor is a chat turn, compactor
      # re-renders the system message per AGENTS.md exception).
      #
      # History:  [old_system, old_user, old_assistant, tool_call_assistant,
      #             tool_result, [mode: compact] suffix, compactor_assistant,
      #             marker]
      # Messages: [new_system_fresh, summary_user, post_chat_assistant]
      #             (the carried tool_call was executed by the post-swap
      #              chat turn, so it's consumed and replaced with the
      #              final assistant response)
      #
      # Index positions vary; assert by role + content.

      # The fresh system message is the head of the active
      # list (re-rendered from the latest DB vocation + AGENTS.md
      # at compaction time).
      assert match?({:system, _}, Enum.at(messages, 0)),
             "expected fresh system message at messages[0]; got #{inspect(Enum.at(messages, 0))}"

      # The summary_user (compactor's summary) follows the
      # fresh system.
      assert Enum.any?(messages, fn
               {:user, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
                 String.starts_with?(t, "Summary of earlier conversation:")

               _ ->
                 false
             end),
             "expected a summary_user in the active chat"

      # The fresh system message's text contains the
      # rendered system prompt (vocation `system_prompt`
      # plus tool budget / context limit / delegation sections).
      [{:system, sys_struct} | _] = messages

      sys_text =
        sys_struct.parts
        |> Enum.map_join("", fn
          %Part.Text{text: text} -> text
          _ -> ""
        end)

      assert sys_text =~ "Test programmer prompt.",
             "expected fresh system message to contain the rendered system prompt"

      # The carried tool_call was executed by the post-swap
      # chat turn (Trigger 2 mid-turn resume), so the
      # tool_call + tool_result are consumed and replaced
      # with the final assistant response. Assert the tail
      # carries an assistant message.
      assert Enum.any?(messages, &match?({:assistant, _}, &1)),
             "expected a final assistant message in the active chat"

      # Compaction marker in history.
      assert Enum.any?(history, fn
               {:compaction, %{archived_count: n}} when n > 0 -> true
               _ -> false
             end),
             "expected chat:compaction marker in history with archived_count > 0"

      # The original system message is now in history
      # (the swap archives the pre-swap active list, which
      # included the original system message at index 0).
      assert Enum.any?(history, &match?({:system, _}, &1)),
             "expected the original system message in history"

      # The suffix + compactor's assistant response are in
      # history (they were the pre-swap active messages).
      assert Enum.any?(history, fn
               {:system, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
                 String.starts_with?(t, "[mode: compact]")

               {:user, %{parts: [%Part.Text{text: t}]}} when is_binary(t) ->
                 String.starts_with?(t, "[mode: compact]")

               _ ->
                 false
             end),
             "expected the [mode: compact] suffix in history"

      # Trigger user message archived during the swap.
      assert Enum.any?(history, &match?({:user, _}, &1)),
             "expected the trigger user message archived into history"

      Agent.terminate(pid)
    end
  end
end
