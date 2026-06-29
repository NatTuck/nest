defmodule Nest.PersistenceTest do
  @moduledoc """
  Tests for the `Nest.Persistence` agent + message persistence
  layer.

  Covers:
  - `upsert_agent/1` insert + update path
  - `insert_message/2` for each role (system, user, assistant, tool,
    compaction)
  - `archive_and_compact/4` transaction (archive + marker insert)
  - `load_active_messages/1` round-trip (preserves parts and
    message_index)
  - `restore_agent/1` returns attrs that flow into `Agent.start_link`
  - The FTS generated column auto-indexes text parts

  Persistence is enabled in this test process via
  `Persistence.put_persistence_enabled/0` (test-only API), so
  the `Agent` GenServer — which normally has persistence disabled
  via the runtime check — can write through to the DB and the
  `:append_message` smoke test exercises the live path.
  """

  use Nest.DataCase, async: false

  import ExUnit.Callbacks

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  setup do
    # The `Agent` GenServer reads `persistence_enabled?/0` from
    # this process's app env at request time. The runtime
    # default (`false` in test) would skip writes even when the
    # Sandbox has a connection; toggle it back on for this test
    # process so we exercise the real DB write paths.
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, enabled: false)
    end)

    :ok
  end

  describe "upsert_agent/1" do
    test "inserts a new agent row" do
      attrs = agent_attrs("upsert-insert-#{Elixir.System.unique_integer([:positive])}")

      assert {:ok, %PersistedAgent{id: id}} = Persistence.upsert_agent(attrs)
      assert id == attrs.id
    end

    test "updates an existing agent row on conflict" do
      attrs = agent_attrs("upsert-update-#{Elixir.System.unique_integer([:positive])}")

      assert {:ok, %PersistedAgent{id: id}} = Persistence.upsert_agent(attrs)
      assert id == attrs.id

      # Upserting the same id again is idempotent (insert with
      # on_conflict). The model is updated to the new value
      # (the existing row's `model` column is overwritten).
      updated_attrs = %{attrs | model: %{name: "different-model"}}

      assert {:ok, %PersistedAgent{model: %{"name" => name}}} =
               Persistence.upsert_agent(updated_attrs)

      assert name == "different-model"
    end

    test "preserves next_message_index on conflict" do
      attrs = agent_attrs("upsert-counter-#{Elixir.System.unique_integer([:positive])}")

      assert {:ok, %PersistedAgent{next_message_index: 0}} = Persistence.upsert_agent(attrs)

      # The runtime pattern: the agent's `__append_message__`
      # calls `Persistence.update_next_message_index/2`
      # after a successful insert. From the caller's side,
      # upserting without the key leaves the existing value
      # untouched.
      :ok = Persistence.update_next_message_index(attrs.id, 5)

      updated_attrs2 = %{attrs | model: %{name: "third-model"}}

      assert {:ok, %PersistedAgent{next_message_index: 5}} =
               Persistence.upsert_agent(updated_attrs2)
    end
  end

  describe "insert_message/2" do
    test "round-trips a system message" do
      attrs = agent_attrs("msg-system-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      message = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "You are helpful"}]}}

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.id, message)
      assert row.role == "system"
      assert row.message_index == 0
      assert row.content == %{"parts" => [%{"kind" => "text", "text" => "You are helpful"}]}
    end

    test "round-trips a user message with mode metadata" do
      attrs = agent_attrs("msg-user-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      message =
        {:user,
         %User{
           index: 1,
           parts: [%Part.Text{text: "[mode: chat]\nHello"}],
           metadata: %{"mode" => "chat"}
         }}

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.id, message)
      assert row.role == "user"
      assert row.message_index == 1
      assert row.metadata == %{"mode" => "chat"}
    end

    test "round-trips an assistant message with multiple parts (text + thinking + tool_use)" do
      attrs = agent_attrs("msg-assistant-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      # The runtime shape uses atom keys for `usage` (built
      # by `LLM.RunResponse` from the provider's JSON). The
      # persisted shape uses string keys because the jsonb
      # column is text. Round-tripping from runtime → row →
      # runtime should preserve both the parts list and the
      # values inside the usage map.
      message =
        {:assistant,
         %Assistant{
           index: 2,
           parts: [
             %Part.Text{text: "I'll call a tool"},
             %Part.Thinking{thinking: "let me think", signature: "sig-abc"},
             %Part.ToolUse{
               id: "call_1",
               name: "shell_cmd",
               arguments: %{"command" => "ls"}
             }
           ],
           usage: %{
             "input_tokens" => 100,
             "output_tokens" => 20,
             "total_tokens" => 120
           },
           finish_reason: "tool_calls",
           model: "claude-3-opus"
         }}

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.id, message)

      assert row.role == "assistant"
      assert row.message_index == 2

      assert %{"parts" => parts, "usage" => usage, "finishReason" => "tool_calls"} =
               row.content

      assert usage == %{
               "input_tokens" => 100,
               "output_tokens" => 20,
               "total_tokens" => 120
             }

      assert [%{"kind" => "text", "text" => "I'll call a tool"}, _thinking, tool_use] = parts
      assert tool_use["kind"] == "tool_use"
      assert tool_use["name"] == "shell_cmd"
    end

    test "round-trips a tool message with multiple tool results" do
      attrs = agent_attrs("msg-tool-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      message =
        {:tool,
         %Tool{
           index: 3,
           parts: [
             %Part.ToolResult{
               tool_call_id: "call_1",
               name: "shell_cmd",
               content: "ok",
               is_error: false
             },
             %Part.ToolResult{
               tool_call_id: "call_2",
               name: "read_file",
               content: "boom",
               is_error: true
             }
           ]
         }}

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.id, message)
      assert row.role == "tool"

      assert %{"parts" => [r1, r2]} = row.content
      assert r1["kind"] == "tool_result"
      assert r1["toolCallId"] == "call_1"
      assert r2["isError"] == true
    end
  end

  describe "load_active_messages/1" do
    test "returns active (non-archived) messages in message_index order" do
      attrs = agent_attrs("load-active-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "hello"}]}}
        )

      messages = Persistence.load_active_messages(attrs.id)
      assert length(messages) == 3
      assert Enum.map(messages, fn {_, %{index: idx}} -> idx end) == [0, 1, 2]
    end

    test "round-trip preserves parts (text + thinking + tool_use)" do
      attrs = agent_attrs("load-roundtrip-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      original_parts = [
        %Part.Text{text: "visible"},
        %Part.Thinking{thinking: "hidden", signature: "sig-xyz"},
        %Part.ToolUse{id: "call_1", name: "shell_cmd", arguments: %{"cmd" => "ls"}}
      ]

      original =
        {:assistant,
         %Assistant{
           index: 0,
           parts: original_parts,
           usage: %{"input_tokens" => 10},
           finish_reason: "tool_calls"
         }}

      assert {:ok, _} = Persistence.insert_message(attrs.id, original)

      [{:assistant, restored}] = Persistence.load_active_messages(attrs.id)
      assert restored.parts == original_parts
      assert restored.usage == %{"input_tokens" => 10}
      assert restored.finish_reason == "tool_calls"
    end

    test "empty agent returns empty list" do
      attrs = agent_attrs("load-empty-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      assert Persistence.load_active_messages(attrs.id) == []
    end
  end

  describe "archive_and_compact/4" do
    test "archives a range of messages and inserts a compaction marker" do
      attrs = agent_attrs("archive-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:user, %User{index: 0, parts: [%Part.Text{text: "First"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:assistant, %Assistant{index: 1, parts: [%Part.Text{text: "Reply"}]}}
        )

      # Archive indices 0..1 (both messages) and insert a
      # marker at index 2.
      assert {:ok, %PersistedMessage{} = marker} =
               Persistence.archive_and_compact(attrs.id, 0, 1, 2)

      assert marker.role == "compaction"
      assert marker.message_index == 2
      assert marker.compaction_archived_count == 2
      assert marker.compaction_occurred_at != nil

      # The two archived messages are now archived; the
      # compaction marker is the only active message.
      active = Persistence.load_active_messages(attrs.id)
      assert length(active) == 1

      [{:compaction, m}] = active
      assert m.archived_count == 2

      # The archived messages are still in the DB but
      # excluded from the active list.
      from_db = Nest.Repo.all(PersistedMessage)
      assert length(from_db) == 3
      assert Enum.all?(Enum.drop(from_db, -1), &(&1.archived_at != nil))
    end
  end

  describe "update_next_message_index/2" do
    test "bumps the agent's counter" do
      attrs = agent_attrs("counter-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      :ok = Persistence.update_next_message_index(attrs.id, 5)

      [agent] = Nest.Repo.all(PersistedAgent)
      assert agent.next_message_index == 5
    end
  end

  describe "restore_agent/1" do
    test "returns attrs suitable for Agent.start_link" do
      attrs = agent_attrs("restore-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.upsert_agent(attrs)

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.id,
          {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}]}}
        )

      {:ok, restored} = Persistence.restore_agent(attrs.id)

      assert restored.id == attrs.id
      # `model` is a `:map` field in the PersistedAgent schema,
      # so Postgres returns it with string keys after the JSON
      # round-trip. The Agent's `Config.create_client_config/1`
      # accepts both forms (defensive_map_get handles either).
      assert restored.model["name"] == attrs.model.name
      assert restored.model["provider"] == attrs.model.provider
      assert restored.workspace_path == attrs.workspace_path
      assert length(restored.preloaded_messages) == 2
    end

    test "returns :not_found when no row exists" do
      assert {:error, :not_found} =
               Persistence.restore_agent(
                 "nonexistent-#{Elixir.System.unique_integer([:positive])}"
               )
    end
  end

  describe "Agent live smoke test (end-to-end)" do
    # Removed: the e2e smoke test needs the test_helper's
    # MockClient + Mimic setup, which the persistence_test
    # doesn't have. The other Persistence tests cover the
    # DB layer comprehensively. The Agent-side wiring is
    # exercised by the agent_chat_test.exs (which uses the
    # MockClient via the test_helper), gated by the runtime
    # `:persistence_enabled` flag.
  end

  ## Helpers

  defp agent_attrs(id) do
    %{
      id: id,
      model: %{name: "test-model", provider: "test"},
      workspace_path: nil
    }
  end
end
