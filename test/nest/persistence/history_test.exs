defmodule Nest.Persistence.HistoryTest do
  @moduledoc """
  Tests for `Nest.Persistence.History` — the paged reader behind
  `chat:history`.

  The archive is never shipped whole, so `load_slice/3` must bound both
  ends: at most `:limit` rows, at or below the agent's compaction
  boundary, before an exclusive `:before` cursor, and optionally
  restricted to `:roles`. A clone's slice must include the inherited
  prefix below its fork, including the `fork == 0` edge (shares
  nothing).
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Persistence.History

  describe "load_slice/3 paging" do
    test "returns the newest page ascending and walks back with before" do
      %{space_id: space_id, name: name, boundary: boundary} = compacted_agent(9)
      insert_sequence(space_id, name, 0..boundary, fn i -> user_message(i) end)

      assert indexes(History.load_slice(space_id, name, limit: 4)) == [6, 7, 8, 9]

      assert indexes(History.load_slice(space_id, name, limit: 4, before: 6)) == [2, 3, 4, 5]

      assert indexes(History.load_slice(space_id, name, limit: 4, before: 2)) == [0, 1]

      # Walking past index 0 yields an empty page (the stop condition).
      assert History.load_slice(space_id, name, limit: 4, before: 0) == []
    end

    test "defaults to the module page size and returns the whole archive when unbounded" do
      %{space_id: space_id, name: name, boundary: boundary} = compacted_agent(2)
      insert_sequence(space_id, name, 0..boundary, fn i -> user_message(i) end)

      assert indexes(History.load_slice(space_id, name, [])) == [0, 1, 2]

      # `load/2` is the unbounded form (used by chat:api-logs audit).
      assert indexes(History.load(space_id, name)) == [0, 1, 2]
    end
  end

  describe "load_slice/3 role filter" do
    test "restricts the page to the requested roles" do
      %{space_id: space_id, name: name} = compacted_agent(5)

      for message <- [
            user_message(0),
            assistant_message(1),
            user_message(2),
            tool_message(3),
            user_message(4),
            assistant_message(5)
          ] do
        {:ok, _} = Persistence.insert_message(space_id, name, message)
      end

      assert indexes(History.load_slice(space_id, name, roles: ["user"])) == [0, 2, 4]

      assistants = History.load_slice(space_id, name, roles: ["assistant"])
      assert indexes(assistants) == [1, 5]
      assert Enum.all?(assistants, &match?({:assistant, _}, &1))
    end
  end

  describe "load_slice/3 boundaries" do
    test "returns [] for an agent that has never compacted" do
      attrs = agent_attrs(unique_name("never"))
      {:ok, _} = Persistence.insert_agent(attrs)
      {:ok, _} = Persistence.insert_message(attrs.space_id, attrs.name, user_message(0))

      assert History.load_slice(attrs.space_id, attrs.name, []) == []
    end

    test "returns [] for a missing agent" do
      assert History.load_slice(test_space_id(), "does-not-exist", []) == []
    end
  end

  describe "load_slice/3 clone prefix" do
    test "includes the inherited prefix below the fork alongside the clone's own rows" do
      {space_id, child_name} = clone_fixture(fork: 3, boundary: 4)

      slice = History.load_slice(space_id, child_name, [])
      assert indexes(slice) == [0, 1, 2, 3, 4]
    end

    test "a fork of 0 shares nothing: only the clone's own rows are returned" do
      {space_id, child_name} = clone_fixture(fork: 0, boundary: 4)

      slice = History.load_slice(space_id, child_name, [])
      assert indexes(slice) == [3, 4]
    end
  end

  # ---- helpers ----

  defp compacted_agent(boundary) do
    attrs = agent_attrs(unique_name("agent"))

    {:ok, %PersistedAgent{}} =
      Persistence.insert_agent(Map.put(attrs, :last_compaction_index, boundary))

    Map.put(attrs, :boundary, boundary)
  end

  # Parent owns indices 0..2 (boundary 2); the clone owns 3..4 and
  # inherits prefix rows below its fork.
  defp clone_fixture(opts) do
    fork = Keyword.fetch!(opts, :fork)
    boundary = Keyword.fetch!(opts, :boundary)
    parent_attrs = agent_attrs(unique_name("clone-parent"))

    {:ok, %PersistedAgent{id: parent_id}} =
      Persistence.insert_agent(Map.put(parent_attrs, :last_compaction_index, 2))

    insert_sequence(parent_attrs.space_id, parent_attrs.name, 0..2, fn i -> user_message(i) end)

    child_name = unique_name("clone")

    child_attrs =
      parent_attrs
      |> Map.put(:name, child_name)
      |> Map.put(:parent_id, parent_id)
      |> Map.put(:fork_message_index, fork)
      |> Map.put(:last_compaction_index, boundary)

    {:ok, %PersistedAgent{}} = Persistence.insert_agent(child_attrs)

    insert_sequence(parent_attrs.space_id, child_name, 3..4, fn i -> user_message(i) end)

    {parent_attrs.space_id, child_name}
  end

  defp insert_sequence(space_id, name, range, build) do
    for i <- range do
      {:ok, _} = Persistence.insert_message(space_id, name, build.(i))
    end
  end

  defp user_message(index) do
    {:user, %User{index: index, parts: [%Part.Text{text: "user #{index}"}]}}
  end

  defp assistant_message(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "assistant #{index}"}]}}
  end

  defp tool_message(index) do
    {:tool,
     %Tool{
       index: index,
       parts: [%Part.ToolResult{tool_call_id: "c#{index}", name: "t", content: "ok"}]
     }}
  end

  defp indexes(rows), do: Enum.map(rows, fn {_role, %{index: idx}} -> idx end)

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
