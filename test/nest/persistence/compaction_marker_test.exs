defmodule Nest.Persistence.CompactionMarkerTest do
  @moduledoc """
  Tests for `Nest.Persistence.CompactionMarker` — the marker-row
  persistence helper extracted from `Nest.Persistence` to keep
  that module under the 500-line credo cap.

  Covers the one behaviour that only a mixed token-stat pair
  reaches: an explicitly `nil` stat leaves its column unset
  without disturbing the other column.

  The rest of `record/6` is asserted through the same function
  by sibling suites, which reach it via
  `Persistence.insert_message/4`:

  - all-integers write — `agent_compaction_persistence_test.exs`
    ("compaction tuple writes a role:compaction row AND bumps
    agents.last_compaction_index atomically").
  - all-`nil` (legacy) write — `agent_persistence_test.exs`
    ("the 3-arity form uses the default-arg branch").
  - `last_compaction_index` bump — `persistence_test.exs`
    ("inserts a compaction marker row at marker_index and bumps
    last_compaction_index").
  - rollback of the bump when the INSERT fails —
    `agent_compaction_persistence_test.exs` and
    `persistence_test.exs` (both "rolls back ..." tests).
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Persistence.CompactionMarker

  test "record/6 leaves an explicitly nil token stat unset and keeps the other column" do
    attrs = agent_attrs("cm-tokens-mixed-#{Elixir.System.unique_integer([:positive])}")
    {:ok, %PersistedAgent{id: agent_id}} = Nest.Persistence.insert_agent(attrs)

    assert {:ok, %PersistedMessage{} = marker} =
             CompactionMarker.record(agent_id, 5, 3, 1, nil, 4_096)

    assert marker.compaction_tokens_compacted == nil
    assert marker.compaction_tokens_compacted_to == 4_096

    assert {:ok, %PersistedMessage{} = marker} =
             CompactionMarker.record(agent_id, 6, 3, 1, 18_432, nil)

    assert marker.compaction_tokens_compacted == 18_432
    assert marker.compaction_tokens_compacted_to == nil
  end
end
