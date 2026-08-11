defmodule Nest.Agents.PersistedMessageTest do
  @moduledoc """
  Tests for `Nest.Agents.PersistedMessage`'s selective
  `apiLogs` round-trip on the `content` jsonb.

  Pins the contract:

  - `:assistant` rows carry `"apiLogs"` with the runtime list
    (and the runtime list round-trips back via `to_runtime/1`).
  - `:system` rows carry `"apiLogs" => []` even when the
    runtime `api_logs` is empty/nil.
  - `:user` and `:tool` rows do NOT carry `"apiLogs"` in
    `content` — those messages' request payloads are rebuilt on
    restore by `Nest.Agents.Agent.Restore` to avoid O(n²)
    storage cost.
  - Legacy rows without `"apiLogs"` read back as `api_logs: []`.

  `async: false` because `:persistence_enabled` is toggled on
  in the setup block (mirrors `test/nest/persistence_test.exs`).
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence

  describe "serialize_content (assistant apiLogs)" do
    test "round-trips a non-empty api_logs list through insert_message/2 + to_runtime/1" do
      attrs = agent_attrs("asm-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      log1 = %{
        id: "003.000",
        timestamp: DateTime.utc_now(),
        type: :request,
        payload: %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      }

      log2 = %{
        id: "003.001",
        timestamp: DateTime.utc_now(),
        type: :response,
        payload: %{"content" => "hello"}
      }

      message =
        {:assistant,
         %Assistant{
           index: 3,
           parts: [%Part.Text{text: "hello"}],
           api_logs: [log1, log2]
         }}

      assert {:ok, row} = Persistence.insert_message(test_space_id(), attrs.name, message)

      assert is_list(row.content["apiLogs"])
      assert length(row.content["apiLogs"]) == 2

      restored = PersistedMessage.to_runtime(row)
      assert {:assistant, %Assistant{api_logs: api_logs}} = restored
      assert is_list(api_logs)
      assert length(api_logs) == 2

      assert Enum.at(api_logs, 0).id == "003.000"
      assert Enum.at(api_logs, 0).type == :request
      assert Enum.at(api_logs, 1).id == "003.001"
      assert Enum.at(api_logs, 1).type == :response
    end

    test "writes apiLogs: [] when runtime api_logs is empty or nil (always-write contract)" do
      attrs = agent_attrs("asm-empty-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      empty_msg =
        {:assistant, %Assistant{index: 1, parts: [%Part.Text{text: "hi"}], api_logs: []}}

      nil_msg =
        {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "hi"}], api_logs: nil}}

      assert {:ok, row1} = Persistence.insert_message(test_space_id(), attrs.name, empty_msg)
      assert {:ok, row2} = Persistence.insert_message(test_space_id(), attrs.name, nil_msg)

      # Both rows have `apiLogs: []` — the key is ALWAYS present.
      assert row1.content["apiLogs"] == []
      assert row2.content["apiLogs"] == []
    end
  end

  describe "serialize_content (system apiLogs)" do
    test "writes apiLogs: [] for system rows" do
      attrs = agent_attrs("sys-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      message = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      assert {:ok, row} = Persistence.insert_message(test_space_id(), attrs.name, message)
      assert row.content["apiLogs"] == []
    end
  end

  describe "serialize_content (user/tool apiLogs)" do
    test "user rows have NO apiLogs key in content, even when runtime api_logs is set" do
      attrs = agent_attrs("usr-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      log = %{
        id: "  1.000",
        timestamp: DateTime.utc_now(),
        type: :request,
        payload: %{"messages" => []}
      }

      message =
        {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}], api_logs: [log]}}

      assert {:ok, row} = Persistence.insert_message(test_space_id(), attrs.name, message)
      refute Map.has_key?(row.content, "apiLogs")
    end

    test "tool rows have NO apiLogs key in content" do
      attrs = agent_attrs("tool-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      message =
        {:tool,
         %Nest.Messages.Tool{
           index: 2,
           parts: [
             %Part.ToolResult{tool_call_id: "c1", name: "shell_cmd", content: "ok"}
           ]
         }}

      assert {:ok, row} = Persistence.insert_message(test_space_id(), attrs.name, message)
      refute Map.has_key?(row.content, "apiLogs")
    end
  end

  describe "to_runtime/1 backward compat" do
    test "assistant row without apiLogs key in content reads back as api_logs: []" do
      attrs = agent_attrs("legacy-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      # Insert a normal assistant message, then strip the apiLogs
      # key to simulate a legacy row.
      message =
        {:assistant, %Assistant{index: 0, parts: [%Part.Text{text: "hello"}], api_logs: []}}

      assert {:ok, row} = Persistence.insert_message(test_space_id(), attrs.name, message)

      # Hand-build a PersistedMessage with no apiLogs key to
      # simulate a row persisted before the api_log persistence
      # change landed.
      stripped =
        %PersistedMessage{
          id: row.id,
          agent_id: row.agent_id,
          message_index: row.message_index,
          role: row.role,
          content: Map.delete(row.content, "apiLogs"),
          metadata: row.metadata,
          inserted_at: row.inserted_at
        }

      assert {:assistant, %Assistant{api_logs: []}} = PersistedMessage.to_runtime(stripped)
    end

    test "system row without apiLogs key reads back as api_logs: []" do
      attrs = agent_attrs("legacy-sys-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      message = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      assert {:ok, row} = Persistence.insert_message(test_space_id(), attrs.name, message)

      stripped = %PersistedMessage{
        id: row.id,
        agent_id: row.agent_id,
        message_index: row.message_index,
        role: row.role,
        content: Map.delete(row.content, "apiLogs"),
        metadata: row.metadata,
        inserted_at: row.inserted_at
      }

      assert {:system, %MsgSystem{api_logs: []}} = PersistedMessage.to_runtime(stripped)
    end
  end

  describe "compaction token-stat round-trip" do
    test "from_runtime writes compaction_tokens_compacted columns when the marker carries stats" do
      marker = %Compaction{
        index: 5,
        archived_count: 4,
        tokens_compacted: 18_432,
        tokens_compacted_to: 4_096,
        occurred_at: nil,
        metadata: nil
      }

      # The first arg to `from_runtime/2` is the integer agent FK,
      # ignored here — we're exercising the marker-path branch.
      base = PersistedMessage.from_runtime(0, {:compaction, marker})

      assert base.compaction_tokens_compacted == 18_432
      assert base.compaction_tokens_compacted_to == 4_096
    end

    test "from_runtime omits token columns when both stats are nil" do
      marker = %Compaction{
        index: 5,
        archived_count: 4,
        tokens_compacted: nil,
        tokens_compacted_to: nil,
        occurred_at: nil,
        metadata: nil
      }

      base = PersistedMessage.from_runtime(0, {:compaction, marker})

      refute Map.has_key?(base, :compaction_tokens_compacted)
      refute Map.has_key?(base, :compaction_tokens_compacted_to)
    end

    test "to_runtime reads nil stats on a legacy compaction row" do
      attrs = agent_attrs("legacy-compaction-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      # Insert a marker via record_compaction with the legacy
      # 3-arity (default-arg) call so the token columns stay
      # unset (pre-migration marker row shape).
      assert {:ok, marker_row} = Persistence.record_compaction(test_space_id(), attrs.name, 4, 3)

      # Strip any token-stat columns the migration might have
      # populated by accident — simulate a row persisted before
      # the migration ran.
      stripped = %PersistedMessage{
        id: marker_row.id,
        agent_id: marker_row.agent_id,
        message_index: marker_row.message_index,
        role: marker_row.role,
        content: marker_row.content,
        metadata: marker_row.metadata,
        inserted_at: marker_row.inserted_at,
        compaction_archived_count: marker_row.compaction_archived_count,
        compaction_occurred_at: marker_row.compaction_occurred_at,
        compaction_tokens_compacted: nil,
        compaction_tokens_compacted_to: nil
      }

      assert {:compaction,
              %Compaction{
                archived_count: 3,
                tokens_compacted: nil,
                tokens_compacted_to: nil
              }} = PersistedMessage.to_runtime(stripped)
    end
  end
end
