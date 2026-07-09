defmodule Nest.Messages.CompactionTest do
  @moduledoc """
  Pin tests for `Nest.Messages.Compaction.to_json/1` — the
  wire-format serializer for the boundary marker.

  Covers:
  - Default-shape marker emits the expected fields.
  - Marker with token stats carries both `tokensCompacted`
    and `tokensCompactedTo` through to JSON.
  - `format_timestamp/1` DateTime clause produces an ISO8601
    string (the branch not exercised by the agent-level
    restore tests, which seed `occurred_at: nil`).

  Coverage focus: the `format_timestamp/1` clauses.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Compaction

  describe "to_json/1" do
    test "emits the canonical shape with nil token stats" do
      marker = %Compaction{
        index: 5,
        archived_count: 3,
        occurred_at: nil
      }

      assert Compaction.to_json(marker) == %{
               "index" => 5,
               "role" => "compaction",
               "archivedCount" => 3,
               "tokensCompacted" => nil,
               "tokensCompactedTo" => nil,
               "occurredAt" => nil,
               "apiLogs" => []
             }
    end

    test "passes token stats through to the wire format" do
      marker = %Compaction{
        index: 6,
        archived_count: 4,
        tokens_compacted: 18_432,
        tokens_compacted_to: 4_096,
        occurred_at: nil
      }

      json = Compaction.to_json(marker)

      assert json["tokensCompacted"] == 18_432
      assert json["tokensCompactedTo"] == 4_096
    end

    test "ISO8601-stringifies a DateTime occurred_at" do
      now = ~U[2026-07-08 16:00:00Z]

      json =
        Compaction.to_json(%Compaction{
          index: 7,
          archived_count: 2,
          occurred_at: now
        })

      assert json["occurredAt"] == "2026-07-08T16:00:00Z"
    end
  end
end
