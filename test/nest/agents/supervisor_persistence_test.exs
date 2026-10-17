defmodule Nest.Agents.SupervisorPersistenceTest do
  @moduledoc """
  Regression tests for `Supervisor.get_agent/1` with persistence enabled.

  These tests must use `Nest.DataCase` (a sandboxed connection)
  because they exercise the DB-backed on-demand-load path. Kept
  in a separate file from `supervisor_test.exs` so the
  in-process `Registry`-only tests in that file can stay
  `async: true`.

  The regressed production crash was:
    AgentChannel.join("agent:" <> name)
      → Agents.get_agent(name)
      → Supervisor.get_agent(name)
      → Supervisor.fetch_or_start_agent(%{name: name})    # only :name
      → safe_fetch_for_start(name) → {:error, :not_found}
      → do_insert_and_start(%{name: name}, 1)              # no :model
      → Persistence.insert_agent(%{name: name})
      → Map.fetch!(attrs, :model)                          # KeyError

  The fix returns `:not_found` from `fetch_or_start_agent/2`
  when an explicit name has no DB row, instead of falling through
  to `do_insert_and_start/2` with a partial attrs map.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Vocations

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    :ok
  end

  defp test_vocation_id do
    {:ok, %Vocations.Vocation{id: id}} =
      Vocations.upsert_vocation(%{
        name: "Supervisor Persistence Test Default",
        description: "Default for supervisor persistence tests",
        system_prompt: "You are a helpful test assistant.",
        tools: ["context"]
      })

    id
  end

  describe "get_agent/1" do
    test "returns :not_found (not a crash) for an explicit name not in the DB" do
      name = "missing-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} =
               Supervisor.get_agent(AgentTestHelpers.current_space_id(), name)
    end

    test "starts the agent when the row is in the DB but not in the Registry" do
      name = "rebuilt-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Persistence.insert_agent(%{
          space_id: AgentTestHelpers.current_space_id(),
          name: name,
          model: %{name: "qwen3.5-plus"},
          vocation_id: test_vocation_id()
        })

      # `Supervisor.fetch_or_start_agent/1` (under
      # `Supervisor.get_agent/1`) lazily starts the BEAM pid
      # on the registry lookup. Without `ensure_cleanup/1`,
      # the pid would persist into other parallel tests'
      # scope — the registry holds a reference, the test pid
      # has exited, and any subsequent DB call by the agent
      # fails with `DBConnection.OwnershipError`.
      AgentTestHelpers.ensure_cleanup(name)

      assert {:ok, pid} = Supervisor.get_agent(AgentTestHelpers.current_space_id(), name)
      assert is_pid(pid)
      assert Process.alive?(pid)

      Supervisor.stop_agent(AgentTestHelpers.current_space_id(), name)
    end
  end

  describe "build_attrs_for_start/2 with an archive" do
    # Issue #52: the cold start reads the active slice as messages and the
    # archive as three facts. The runtime never holds the archived rows
    # (`ChatState` keeps only `messages`; `Nest.Persistence.History` derives
    # the archive on demand), so decoding their payloads was pure cost — and
    # it made the cost scale with the whole conversation instead of the
    # active window.
    test "reads the active slice as messages and summarizes the archive" do
      {space_id, name} = seed_compacted(active: 2, archived: 3)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)

      assert indices(attrs.preloaded_messages) == [4, 5]

      assert attrs.archived_summary == %{
               has_system_row: true,
               highest_index: 3,
               marker_count: 1
             }
    end

    test "seeds the active slice with the archive's facts" do
      {space_id, name} = seed_compacted(active: 2, archived: 3)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      state = Init.build_active_state(attrs, client_config())

      assert indices(state.chat_state.messages) == [4, 5]
      assert state.chat_state.last_compaction_index == 3
      assert state.chat_state.compaction_count == 1
      # One past the highest index of the *logical* sequence: the archived
      # maximum is what carries it when the active slice cannot.
      assert state.chat_state.next_message_index == 6
    end

    test "keeps the counters clear of the archive when the active slice is empty" do
      {space_id, name} = seed_compacted(active: 0, archived: 3)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.preloaded_messages == []

      state = Init.build_active_state(attrs, client_config())

      # The in-memory system row stays where `build_state/2` put it, and the
      # counters clear the archive so the next append cannot collide with a
      # row that is already there.
      assert indices(state.chat_state.messages) == [0]
      assert state.chat_state.compaction_count == 1
      assert state.chat_state.next_message_index == 4
    end

    test "keeps a fresh agent's in-memory system row" do
      space_id = AgentTestHelpers.current_space_id()
      name = "fresh-#{System.unique_integer([:positive])}"

      {:ok, _row} = insert_agent_row(space_id, name, 0)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.preloaded_messages == []

      assert attrs.archived_summary == %{
               has_system_row: false,
               highest_index: -1,
               marker_count: 0
             }

      state = Init.build_active_state(attrs, client_config())

      # No rows and no archive: the system row `build_state/2` composed stays
      # where it is, and the next append takes index 1.
      assert indices(state.chat_state.messages) == [0]
      assert state.chat_state.next_message_index == 1
    end

    test "counts the markers a clone inherited through its shared prefix" do
      {space_id, parent} = seed_compacted(active: 2, archived: 3)
      {:ok, parent_row} = Persistence.fetch_agent(space_id, parent)

      # A clone forked at 4 that inherited the parent's boundary: its own rows
      # start above the fork, so the marker at 3 — the boundary it inherited —
      # lives in the parent's rows. Only the archive read resolves it.
      child = "clone-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Persistence.insert_agent(%{
          space_id: space_id,
          name: child,
          model: %{name: "qwen3.5-plus"},
          vocation_id: test_vocation_id(),
          parent_id: parent_row.id,
          fork_message_index: 4,
          last_compaction_index: 3,
          next_message_index: 6
        })

      insert(space_id, child, user(4))
      insert(space_id, child, assistant(5))

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, child)

      assert attrs.archived_summary == %{
               has_system_row: true,
               highest_index: 3,
               marker_count: 1
             }

      state = Init.build_active_state(attrs, client_config())
      assert state.chat_state.compaction_count == 1
      assert indices(state.chat_state.messages) == [4, 5]
    end
  end

  # 0 is the system row, 1..`archived - 1` are archived rows, `archived` is the
  # boundary marker, and the `active` rows run above it. The active slice
  # alternates user/assistant so an even count ends on an assistant, which
  # keeps the load path from appending a bridge.
  defp seed_compacted(opts) do
    space_id = AgentTestHelpers.current_space_id()
    name = "compacted-#{System.unique_integer([:positive])}"
    active = Keyword.fetch!(opts, :active)
    archived = Keyword.fetch!(opts, :archived)

    {:ok, _row} = insert_agent_row(space_id, name, archived + active + 1)

    insert(space_id, name, system(0))
    seed_archived_rows(space_id, name, archived)
    {:ok, _} = Persistence.record_compaction(space_id, name, archived, archived)
    seed_active_rows(space_id, name, archived, active)

    {space_id, name}
  end

  defp insert_agent_row(space_id, name, next_index) do
    Persistence.insert_agent(%{
      space_id: space_id,
      name: name,
      model: %{name: "qwen3.5-plus"},
      vocation_id: test_vocation_id(),
      next_message_index: next_index
    })
  end

  defp seed_archived_rows(space_id, name, archived) do
    for i <- 1..(archived - 1)//1 do
      insert(space_id, name, if(rem(i, 2) == 1, do: user(i), else: assistant(i)))
    end
  end

  defp seed_active_rows(space_id, name, archived, active) do
    for k <- 1..active//1 do
      index = archived + k
      insert(space_id, name, if(rem(k, 2) == 1, do: user(index), else: assistant(index)))
    end
  end

  defp insert(space_id, name, message) do
    {:ok, _} = Persistence.insert_message(space_id, name, message)
  end

  defp indices(messages), do: Enum.map(messages, fn {_role, %{index: index}} -> index end)

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index) do
    {:user, %User{index: index, parts: [%Part.Text{text: "u#{index}"}]}}
  end

  defp assistant(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "a#{index}"}], api_logs: []}}
  end

  defp client_config do
    {:ok, config} = Config.create_client_config(%{name: "qwen3.5-plus"})
    config
  end
end
