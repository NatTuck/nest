defmodule Nest.Persistence.CompactionMarkerTest do
  @moduledoc """
  Tests for `Nest.Persistence.CompactionMarker` — the marker-row
  persistence helper extracted from `Nest.Persistence` to keep
  that module under the 500-line credo cap.

  Covers:
  - Marker INSERT writes the `compaction_tokens_compacted` /
    `compaction_tokens_compacted_to` columns when provided.
  - Both columns are nullable — passing `nil` for either leaves
    the column unset (legacy callers and pre-migration rows).
  - The `agents.last_compaction_index` boundary bump commits
    atomically with the marker INSERT (one transaction).
  - `record/5` returns `:not_found` when the row insert fails
    (the `Repo.rollback` path).

  Persistence is enabled in this test process via the `:nest,
  :persistence` app env (test-only override) so the writes
  commit to the sandboxed connection.
  """

  use Nest.DataCase, async: false

  import Ecto.Query, warn: false
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Persistence.CompactionMarker
  alias PersistedMessage, as: PersistedMessageSchema

  setup do
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, enabled: false)
    end)

    :ok
  end

  describe "record/5 — token stats" do
    test "writes both token-stat columns when both values are integers" do
      attrs = agent_attrs("cm-stats-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = insert_agent(attrs)

      assert {:ok, %PersistedMessage{} = marker} =
               CompactionMarker.record(agent_id, 5, 3, 18_432, 4_096)

      assert marker.compaction_tokens_compacted == 18_432
      assert marker.compaction_tokens_compacted_to == 4_096
    end

    test "leaves compaction_tokens_compacted nil when caller passes nil" do
      attrs = agent_attrs("cm-tokens-nil-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = insert_agent(attrs)

      assert {:ok, %PersistedMessage{} = marker} =
               CompactionMarker.record(agent_id, 5, 3, nil, 4_096)

      assert marker.compaction_tokens_compacted == nil
      assert marker.compaction_tokens_compacted_to == 4_096
    end

    test "leaves compaction_tokens_compacted_to nil when caller passes nil" do
      attrs = agent_attrs("cm-tokens-to-nil-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = insert_agent(attrs)

      assert {:ok, %PersistedMessage{} = marker} =
               CompactionMarker.record(agent_id, 5, 3, 18_432, nil)

      assert marker.compaction_tokens_compacted == 18_432
      assert marker.compaction_tokens_compacted_to == nil
    end

    test "leaves both columns nil when caller passes (nil, nil)" do
      attrs = agent_attrs("cm-both-nil-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = insert_agent(attrs)

      assert {:ok, %PersistedMessage{} = marker} =
               CompactionMarker.record(agent_id, 5, 3, nil, nil)

      assert marker.compaction_tokens_compacted == nil
      assert marker.compaction_tokens_compacted_to == nil
    end
  end

  describe "record/5 — transaction atomicity" do
    test "rolls back the last_compaction_index bump when marker INSERT fails on collision" do
      attrs = agent_attrs("cm-rollback-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = insert_agent(attrs)

      # Pre-insert a row at the marker index to force a unique
      # constraint violation.
      %PersistedMessage{}
      |> changeset(%{
        agent_id: agent_id,
        message_index: 5,
        role: "user",
        content: %{"parts" => []}
      })
      |> Nest.Repo.insert!()

      assert {:error, _reason} =
               CompactionMarker.record(agent_id, 5, 0, 100, 50)

      # Rollback: the boundary column must still be -1.
      agent_row = Nest.Repo.one!(from(a in PersistedAgent, where: a.id == ^agent_id))
      assert agent_row.last_compaction_index == -1
    end

    test "bumps last_compaction_index atomically with the INSERT" do
      attrs = agent_attrs("cm-bump-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = insert_agent(attrs)

      assert {:ok, _marker} = CompactionMarker.record(agent_id, 12, 5, 200, 80)

      agent_row = Nest.Repo.one!(from(a in PersistedAgent, where: a.id == ^agent_id))
      assert agent_row.last_compaction_index == 12
    end
  end

  defp insert_agent(attrs) do
    Nest.Persistence.insert_agent(attrs)
  end

  defp changeset(source, attrs) do
    PersistedMessageSchema.changeset(source, attrs)
  end
end
