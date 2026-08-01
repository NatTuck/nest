defmodule Nest.Agents.AgentCompactionPersistenceTest do
  @moduledoc """
  DB-side coverage for the unified `Persistence.insert_message/2`
  path: every message row (system, user, assistant, tool,
  compaction) flows through one insert primitive. The
  `{:compaction, %Compaction{}}` shape also updates
  `agents.last_compaction_index` atomically in the same
  transaction.

  Companion tests:
  - `compaction_marker_test.exs` — direct `CompactionMarker.record/5`
    coverage (still exercised by `record_compaction/3` callers).
  - `persistence_test.exs` — existing `insert_message/2` and
    `record_compaction/3` tests (retained for backward
    compatibility on the `record_compaction` API).
  - `agent_compaction_system_repeat_test.exs` — agent-level
    coverage of the system-message + tools + AGENTS.md re-read
    on compaction.
  """
  use Nest.DataCase, async: false

  import Ecto.Query, warn: false
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  setup do
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, enabled: false)
    end)

    :ok
  end

  describe "Persistence.insert_message/2 unified compaction clause" do
    test "compaction tuple writes a role:compaction row AND bumps agents.last_compaction_index atomically" do
      attrs = agent_attrs("cm-unified-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = Persistence.insert_agent(attrs)

      marker = %Compaction{
        index: 5,
        archived_count: 3,
        tokens_compacted: 1_024,
        tokens_compacted_to: 256,
        occurred_at: Persistence.now(),
        metadata: nil
      }

      assert {:ok, %PersistedMessage{} = row} =
               Persistence.insert_message(attrs.name, {:compaction, marker})

      assert row.role == "compaction"
      assert row.message_index == 5
      assert row.compaction_archived_count == 3
      assert row.compaction_tokens_compacted == 1_024
      assert row.compaction_tokens_compacted_to == 256

      agent_row = Nest.Repo.one!(from(a in PersistedAgent, where: a.id == ^agent_id))
      assert agent_row.last_compaction_index == 5
    end

    test "compaction tuple rolls back last_compaction_index when the marker INSERT fails on collision" do
      attrs = agent_attrs("cm-rollback-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = Persistence.insert_agent(attrs)

      # Pre-insert a row at the marker index to force a unique-constraint violation.
      %PersistedMessage{}
      |> PersistedMessage.changeset(%{
        agent_id: agent_id,
        message_index: 5,
        role: "user",
        content: %{"parts" => []}
      })
      |> Nest.Repo.insert!()

      marker = %Compaction{
        index: 5,
        archived_count: 0,
        tokens_compacted: nil,
        tokens_compacted_to: nil,
        occurred_at: Persistence.now(),
        metadata: nil
      }

      assert {:error, _reason} =
               Persistence.insert_message(attrs.name, {:compaction, marker})

      # Rollback: boundary column must NOT be bumped.
      agent_row = Nest.Repo.one!(from(a in PersistedAgent, where: a.id == ^agent_id))
      assert agent_row.last_compaction_index == -1
    end

    test "regular (non-compaction) tuple is unchanged by the compaction clause — same persistence semantics as before" do
      attrs = agent_attrs("cm-regular-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = Persistence.insert_agent(attrs)

      system_msg =
        {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "regular"}]}}

      assert {:ok, %PersistedMessage{} = row} =
               Persistence.insert_message(attrs.name, system_msg)

      assert row.role == "system"

      agent_row = Nest.Repo.one!(from(a in PersistedAgent, where: a.id == ^agent_id))
      # Regular inserts don't touch the compaction boundary.
      assert agent_row.last_compaction_index == -1
    end

    test "tool/assistant/user/system tuples all flow through the same insert path as compaction tuples" do
      attrs = agent_attrs("cm-shapes-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = Persistence.insert_agent(attrs)

      messages = [
        {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}},
        {:user, %User{index: 1, parts: [%Part.Text{text: "u"}]}},
        {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "a"}]}},
        {:tool, %Tool{index: 3, parts: []}},
        {:compaction, %Compaction{index: 4, archived_count: 1, occurred_at: Persistence.now()}}
      ]

      results =
        Enum.map(messages, fn stamped ->
          Persistence.insert_message(attrs.name, stamped)
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      rows = Nest.Repo.all(from(m in PersistedMessage, where: m.agent_id == ^agent_id))
      assert length(rows) == 5
      assert Enum.sort(Enum.map(rows, & &1.message_index)) == [0, 1, 2, 3, 4]
      assert Enum.sort(Enum.map(rows, & &1.role)) == ~w(assistant compaction system tool user)
    end
  end

  describe "Persistence.record_compaction/3,5 backward-compat passthrough" do
    test "record_compaction/3 still works as a thin facade over the unified insert path" do
      # `Persistence.record_compaction/3` (and /4, /5) is the
      # pre-unification API. After the unification it remains
      # as a convenience for callers that have positional
      # `(name, index, count, tokens...)` args rather than a
      # `%Compaction{}` struct. Verify both paths produce the
      # same DB result.
      attrs = agent_attrs("cm-facade-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      assert {:ok, %PersistedMessage{} = row} =
               Persistence.record_compaction(attrs.name, 4, 2, 1_000, 200)

      assert row.role == "compaction"
      assert row.message_index == 4
      assert row.compaction_archived_count == 2
      assert row.compaction_tokens_compacted == 1_000
      assert row.compaction_tokens_compacted_to == 200
    end
  end
end
