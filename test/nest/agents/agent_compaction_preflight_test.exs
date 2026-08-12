defmodule Nest.Agents.AgentCompactionPreflightTest do
  @moduledoc """
  Tests for the preflight path: `:cannot_compact` (system
  prompt + reserve exceeds the model's context limit) and
  `:fits` (no compaction needed). Extracted from
  `agent_compaction_test.exs` to keep that file under
  credo's 500-line cap.
  """
  use Nest.DataCase, async: true

  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Compaction Preflight Test #{Elixir.System.unique_integer([:positive])}",
        description: "For preflight tests",
        system_prompt: "Test prompt.",
        tools: ["context"],
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
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id()
        })

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
      assert state_after.live.status == :context_overflow
      assert state_after.live.pending_user_message == nil

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
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id()
        })

      MockClient.set_response("Hello back")

      Agent.chat(pid, "Hello")

      # The user message is broadcast, the chat turn starts,
      # and the LLM responds. No context_overflow status.
      assert_receive {:chat_message, {:user, _}}, 500
      refute_receive {:chat_status, %{status: "context_overflow"}}, 200

      assert_receive {:chat_status, %{status: "idle"}}, 500

      Agent.terminate(pid)
    end
  end

  describe "chat:compaction broadcast" do
    test "compaction_done broadcasts chat:compaction with marker and history" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      old_messages = [
        {:user, %Nest.Messages.User{index: 0, parts: [%Part.Text{text: "First"}], api_logs: []}},
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

  # Build a `{:assistant, %Assistant{}}` with a single
  # `%Part.ToolUse{name: "context"}` at index `idx`.
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
end
