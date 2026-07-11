defmodule Nest.Agents.AgentCompactionPassthroughTest do
  @moduledoc """
  Tests for the compactor's `:too_short` short-circuit.

  The compactor's `:too_short` branch fires when the input
  has nothing meaningful to summarize (single system message,
  system + single user, no head). The agent's
  `compaction_done/3` handler must:

    1. Wrap the spawn return in `{:noreply, state}` so the
       GenServer doesn't crash with "bad return value"
       (returning the bare `state` struct crashes the
       GenServer).
    2. Log at `:debug` only — at `:warning` (the default test
       logger level) every test that triggers `:passthrough`
       would print noise.
    3. Return the agent to `:idle` and spawn the continuation
       (the carry-over tool_call/tool_result pair in the
       `:compact_tool` continuation shape gets picked up by
       the new ChatTurn).

  Extracted from `Nest.Agents.AgentCompactionChatContinuationTest`
  to keep that file under the credo 500-line cap.
  """

  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    # Compaction writes flow through AgentPersistence
    # (gated on `persistence_enabled?`). Enable the flag for
    # the duration of the suite so the marker INSERT and the
    # `last_compaction_index` column bump actually hit the DB.
    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, previous)
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Passthrough Test (#{Elixir.System.unique_integer([:positive])})",
        description: "For :passthrough short-circuit regression tests",
        system_prompt: "Test prompt.",
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

  # Disable persistence for the agent's `init/1` so its
  # `persist_initial_system_message/1` call (which would
  # otherwise fail with `:agent_not_found` and emit
  # `Logger.warning`) is a silent no-op. Re-enable persistence
  # AFTER `start_agent/1` returns, and insert the agents row
  # before driving the compaction cycle. Each test below
  # does this dance.
  defp start_agent_with_row(next_message_index) do
    vocation_id = programmer_vocation_id()

    Application.put_env(:nest, :persistence, enabled: false)

    {pid, agent_id} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    Application.put_env(:nest, :persistence, enabled: true)

    Nest.Persistence.insert_agent(%{
      name: agent_id,
      model: %{name: "qwen3.5-plus"},
      vocation_id: vocation_id
    })

    :sys.replace_state(pid, fn state ->
      %{state | chat_state: %{state.chat_state | next_message_index: next_message_index}}
    end)

    {pid, agent_id}
  end

  # The carried pair for a `:compact_tool` continuation:
  # `[{:assistant, +ToolUse}, {:tool, +ToolResult}]`.
  #
  # `iter` defaults to 0 and `max` defaults to the configured
  # tool-iteration cap, matching the post-refactor
  # `normalize_continuation/2` literal. The handler doesn't
  # inspect `state.chat_state.messages` for the trailing tool
  # call — the pair is carried in the continuation itself.
  defp compact_tool_continuation(iter, max) do
    tool_call_id = "compact_call_#{Elixir.System.unique_integer([:positive])}"
    arguments = %{"action" => "compact"}

    tool_call_msg =
      {:assistant,
       %Assistant{
         index: nil,
         parts: [%Part.ToolUse{id: tool_call_id, name: "context", arguments: arguments}],
         api_logs: []
       }}

    tool_result_msg =
      {:tool,
       %Tool{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [
           %Part.ToolResult{
             tool_call_id: tool_call_id,
             name: "context",
             arguments: arguments,
             content: "Compacted from N token previous context.",
             is_error: false
           }
         ],
         api_logs: []
       }}

    {:compact_tool, [tool_call_msg, tool_result_msg], iter, max}
  end

  describe "compaction_done: :passthrough (conversation too short to compact)" do
    test ":passthrough with a :compact_tool continuation returns agent to :idle and spawns the carried pair",
         %{} do
      {pid, agent_id} = start_agent_with_row(1)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      log =
        capture_log(fn ->
          send(
            pid,
            {:compaction_done, :passthrough, compact_tool_continuation(0, 5)}
          )

          # The :passthrough branch transitions the agent back
          # to :idle without a chat:error broadcast.
          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      # No warning log: the skip is a clean recovery, not an
      # error. (It's logged at :debug — silent at the test
      # default :warning level.)
      refute log =~ "Compaction skipped"

      # No chat:error broadcast either.
      refute_receive {:chat_error, _}, 200

      # The GenServer is still alive after the :passthrough
      # recovery (the wrap prevents the "bad return value"
      # crash). :sys.get_state/2 queues behind the handler.
      assert Process.alive?(pid)
      state = :sys.get_state(pid, 1_000)
      assert state.chat_state.status == :idle

      Agent.terminate(pid)
    end

    test ":passthrough with no continuation just returns :noreply (idempotent idle)",
         %{} do
      {pid, agent_id} = start_agent_with_row(1)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      log =
        capture_log(fn ->
          # nil continuation — the caller expects the agent
          # to settle back to :idle without spawning anything.
          send(pid, {:compaction_done, :passthrough, nil})

          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      refute log =~ "Compaction skipped"

      assert Process.alive?(pid)
      state = :sys.get_state(pid, 1_000)
      assert state.chat_state.status == :idle

      Agent.terminate(pid)
    end
  end
end
