defmodule Nest.Agents.AgentCompactionPersistenceTest do
  @moduledoc """
  Tests for the persistence side of the compaction regeneration
  path. After every compaction, `regenerate_for_compaction/2`
  inserts the fresh system message, the encoded-summary user
  message, and the compactor's other output into the `messages`
  table. This file pins that contract:

  - the fresh system message lands at `marker_index + 1`
  - the encoded summary lands at `marker_index + 2` (when
    extracted)
  - the compactor's other output is persisted in order
  - a BEAM restart after compaction loads the post-compaction
    state, not the pre-compaction history (regression for the
    latent gap where the compactor's output was in-memory only)
  - `agents.last_compaction_index` is bumped to the marker index
    atomically with the marker row INSERT

  The `messages` table is append-only. There is no
  `archived_at` filter on the rows themselves; the
  active/history partition is a view computed from
  `agents.last_compaction_index`.

  This file is `async: false` so the agent's regeneration can
  use the test's sandboxed connection (the agent's process is
  started via `start_supervised!/1` from the test process).
  """

  use Nest.DataCase, async: false

  import Mimic
  import Ecto.Query

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Config, as: AgentConfig
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.LLM.MockClient
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

    # This file exercises the persistence side of compaction
    # (writes go to the messages table + the agents row's
    # last_compaction_index column), so enable the runtime
    # `persistence_enabled?` flag for the duration.
    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, previous)
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  defp test_vocation_id do
    case Process.get(:nest_compaction_persistence_test_vid) do
      nil ->
        {:ok, %Vocations.Vocation{id: id}} =
          Vocations.upsert_vocation(%{
            name: "Compaction Persistence Test Default",
            description: "Default for compaction persistence tests",
            system_prompt: "You are a helpful test assistant.",
            tools: ["context"],
            modes: %{
              "chat" => %{
                "description" => "General conversation.",
                "caps" => %{
                  "net" => false,
                  "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
                }
              }
            }
          })

        Process.put(:nest_compaction_persistence_test_vid, id)
        id

      id ->
        id
    end
  end

  defp insert_agent_row(name, vocation_id) do
    {:ok, row} =
      Persistence.insert_agent(%{
        name: name,
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    row
  end

  # Append an `assistant+ToolUse[context.compact]` to the
  # agent's `state.chat_state.messages` so the messages list
  # ends with the trailing tool call (matching production
  # where the chat turn has already emitted the tool call
  # before the compaction fires). Returns the tool_call_id
  # so the carried pair can reference the same call.
  defp seed_compact_tool_call(pid) do
    tool_call_id = "compact_call_#{Elixir.System.unique_integer([:positive])}"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | chat_state: %{
            state.chat_state
            | messages:
                (state.chat_state.messages || []) ++
                  [
                    {:assistant,
                     %Assistant{
                       index: nil,
                       parts: [
                         %Part.ToolUse{
                           id: tool_call_id,
                           name: "context",
                           arguments: %{"action" => "compact"}
                         }
                       ],
                       api_logs: []
                     }}
                  ]
          }
      }
    end)

    tool_call_id
  end

  # Build the carried `[tool_call, tool_result]` pair for the
  # `:compact_tool` continuation. `iter` defaults to 0 and
  # `max` defaults to the configured tool-iteration cap,
  # matching the post-refactor `normalize_continuation/2`
  # literal. The handler doesn't inspect
  # `state.chat_state.messages` for the trailing tool call —
  # the pair is carried in the continuation itself.
  defp compact_tool_continuation(
         tool_call_id,
         iter \\ 0,
         max \\ AgentConfig.configured_max_tool_iterations()
       ) do
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

  describe "post-compaction persistence" do
    # The agent's `init/1` calls
    # `Nest.Agents.Agent.Init.persist_initial_system_message/1`
    # which routes through `AgentPersistence.append_message/3`.
    # With `enabled: true` (set in `setup/`), that fires
    # `Logger.warning("Failed to persist message for agent …")`
    # for `:agent_not_found` if the agents row doesn't exist
    # yet. AGENTS.md ("tests must not print to the console")
    # forbids that warning. The fix is to pre-insert the agents
    # row BEFORE `start_agent/1` so the agent's init-time
    # append finds the row. Each test below does this.
    defp run_compaction_cycle(pid, _agent_id, summary_text, next_message_index \\ 1) do
      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: next_message_index}}
      end)

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, summary_text, compact_tool_continuation(tool_call_id)}
      )

      # `:task_compaction_done` is gone in the new design —
      # the handler synchronously appends the carried pair
      # via `append_continuation_tail/2`, swaps, and spawns a
      # fresh ChatTurn via `ChatTurnSpawner.spawn/4`. We don't
      # care about the spawned ChatTurn's downstream work
      # for these tests — just that the handler has run. Wait
      # via `:sys.get_state/2` so the test's assertions see
      # the post-swap state.
      _ = :sys.get_state(pid, 500)

      Agent.terminate(pid)
    end

    test "fresh system message lands at marker_index + 1" do
      vocation_id = test_vocation_id()

      # Disable persistence for the agent's `init/1` so its
      # `persist_initial_system_message/1` call (which would
      # otherwise fail with `:agent_not_found` and emit
      # `Logger.warning`) is a silent no-op. Re-enable
      # persistence AFTER `start_agent/1` returns, and insert
      # the `agents` row before driving the compaction cycle.
      Application.put_env(:nest, :persistence, enabled: false)
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})
      Application.put_env(:nest, :persistence, enabled: true)

      insert_agent_row(agent_id, vocation_id)

      run_compaction_cycle(
        pid,
        agent_id,
        "[Summary of earlier conversation]:\n\n..."
      )

      agent_row = Nest.Repo.one!(PersistedAgent, where: [name: agent_id])
      assert agent_row.last_compaction_index == 1

      rows =
        Nest.Repo.all(
          from(m in PersistedMessage,
            where: m.agent_id == ^agent_row.id,
            order_by: [asc: m.message_index]
          )
        )

      assert length(rows) == 3
      assert Enum.map(rows, & &1.message_index) == [1, 2, 3]

      assert Enum.map(rows, & &1.role) == [
               "compaction",
               "system",
               "user"
             ]
    end

    test "encoded summary user message lands at marker_index + 2" do
      vocation_id = test_vocation_id()

      Application.put_env(:nest, :persistence, enabled: false)
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})
      Application.put_env(:nest, :persistence, enabled: true)

      insert_agent_row(agent_id, vocation_id)

      run_compaction_cycle(
        pid,
        agent_id,
        "[Summary of earlier conversation]:\n\nkey facts"
      )

      agent_row = Nest.Repo.one!(PersistedAgent, where: [name: agent_id])
      assert agent_row.last_compaction_index == 1

      rows =
        Nest.Repo.all(
          from(m in PersistedMessage,
            where: m.agent_id == ^agent_row.id,
            order_by: [asc: m.message_index]
          )
        )

      assert length(rows) == 3

      assert [
               %PersistedMessage{role: "compaction", message_index: 1},
               %PersistedMessage{role: "system", message_index: 2},
               %PersistedMessage{role: "user", message_index: 3}
             ] = rows
    end

    test "the carried pair lands at marker_index + 3 and marker_index + 4 in the active list" do
      # The `:compact_tool` continuation's carried
      # `[tool_call, tool_result]` pair is appended to the
      # new compacted state via `append_continuation_tail/2`
      # — they live in `state.chat_state.messages` (the
      # active list) but are NOT yet in the `messages`
      # table. Persistence for the pair happens when the
      # next ChatTurn runs and stamps each message via
      # `__append_message__/2`. This test pins the in-memory
      # contract: the carried pair sits at the post-swap
      # tail in the right order, ready for the next
      # iteration to consume.
      vocation_id = test_vocation_id()

      Application.put_env(:nest, :persistence, enabled: false)
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})
      Application.put_env(:nest, :persistence, enabled: true)

      insert_agent_row(agent_id, vocation_id)

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 1}}
      end)

      tool_call_id = seed_compact_tool_call(pid)

      send(
        pid,
        {:compaction_done, "[Summary of earlier conversation]:\n\nkey facts",
         compact_tool_continuation(tool_call_id)}
      )

      _ = :sys.get_state(pid, 500)

      state_after = :sys.get_state(pid)
      # marker_index = 1; fresh_system@2, summary_user@3,
      # tool_call@4, tool_result@5 — 4 messages in the
      # post-swap active list.
      assert length(state_after.chat_state.messages) == 4

      [fresh, summary, call, result] = state_after.chat_state.messages

      assert {:system, %{index: 2}} = fresh
      assert {:user, %{index: 3}} = summary
      assert {:assistant, %{index: 4}} = call
      assert {:tool, %{index: 5}} = result

      assert state_after.chat_state.next_message_index == 6

      Agent.terminate(pid)
    end

    test "agents.last_compaction_index is bumped to the marker index atomically with the INSERT" do
      # If the marker INSERT succeeds but the column update
      # fails (or vice versa), a restore would see one
      # without the other and produce a wrong partition.
      # `record_compaction/3` wraps both in one
      # Repo.transaction.
      vocation_id = test_vocation_id()

      Application.put_env(:nest, :persistence, enabled: false)
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})
      Application.put_env(:nest, :persistence, enabled: true)

      insert_agent_row(agent_id, vocation_id)

      run_compaction_cycle(
        pid,
        agent_id,
        "[Summary of earlier conversation]:\n\npost-state",
        7
      )

      agent_row = Nest.Repo.one!(PersistedAgent, where: [name: agent_id])
      assert agent_row.last_compaction_index == 7

      marker_row =
        Nest.Repo.one!(
          from(m in PersistedMessage,
            where: m.agent_id == ^agent_row.id and m.role == "compaction"
          )
        )

      assert marker_row.message_index == 7
    end

    test "a BEAM restart after compaction loads the full message sequence in order" do
      # Both the active slice AND the marker are part of the
      # persisted row sequence now; `load_messages/1` returns
      # them in order, and `seed_from_db/3` partitions into
      # history (≤ last_compaction_index) and messages
      # (> last_compaction_index).
      vocation_id = test_vocation_id()

      Application.put_env(:nest, :persistence, enabled: false)
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vocation_id})
      Application.put_env(:nest, :persistence, enabled: true)

      insert_agent_row(agent_id, vocation_id)

      # Pre-seed the agent's messages so there's something
      # to archive.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: [
                  {:user, %User{index: 0, parts: [%Part.Text{text: "Pre"}], api_logs: []}}
                ],
                next_message_index: 1
            }
        }
      end)

      run_compaction_cycle(
        pid,
        agent_id,
        "[Summary of earlier conversation]:\n\npost-state"
      )

      {:ok, attrs} = Persistence.build_attrs_for_start(agent_id)
      assert attrs.last_compaction_index == 1

      # 3 messages in the table: the marker at index 1
      # (the in-memory pre-seed at index 0 never reached
      # the DB — `record_compaction/3` only writes the
      # marker), and the 2 regenerated post-compaction
      # rows at indices 2..3. The carried pair
      # (tool_call, tool_result) is in the in-memory
      # active list but not in the `messages` table yet.
      # The `load_messages/1` full-sequence contract
      # returns the 3 rows in order;
      # `Agent.init/1`'s `seed_from_db/3` then partitions
      # via `index <= last_compaction_index`.
      assert length(attrs.preloaded_messages) == 3

      indices = Enum.map(attrs.preloaded_messages, fn {_, %{index: i}} -> i end)
      assert indices == [1, 2, 3]

      assert Enum.map(attrs.preloaded_messages, fn {role, _} -> role end) == [
               :compaction,
               :system,
               :user
             ]
    end
  end
end
