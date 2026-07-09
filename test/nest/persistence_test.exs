defmodule Nest.PersistenceTest do
  @moduledoc """
  Tests for the `Nest.Persistence` agent + message persistence
  layer. Covers the message and compaction surfaces:

  - `insert_message/2` for each role (system, user, assistant, tool,
    compaction)
  - `insert_message/2` idempotency (the `(agent_id, message_index)`
    unique-constraint regression)
  - `load_messages/1` returns the full ordered sequence (no
    active/history filter at the SQL layer)
  - `record_compaction/3` transaction (marker insert + boundary
    column bump)
  - `last_compaction_index/1` reads the boundary column

  Agent-CRUD tests (insert_agent, fetch_agent_by_name,
  list_agent_names) and build_attrs_for_start live in
  `Nest.PersistenceAgentsTest` to keep each file under
  credo's 500-line limit.

  Persistence is enabled in this test process via the `:nest,
  :persistence` app env (test-only override), so the `Agent`
  GenServer — which normally has persistence disabled via the
  runtime check — can write through to the DB and the
  `:append_message` smoke test exercises the live path.
  """

  use Nest.DataCase, async: false

  import Ecto.Query, warn: false
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Assistant
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

  describe "insert_message/2" do
    test "round-trips a system message" do
      attrs = agent_attrs("msg-system-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      message = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "You are helpful"}]}}

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.name, message)
      assert row.role == "system"
      assert row.message_index == 0

      # System rows always carry the `apiLogs` key (typically `[]`)
      # under the selective api_log persistence design.
      assert row.content == %{
               "parts" => [%{"kind" => "text", "text" => "You are helpful"}],
               "apiLogs" => []
             }
    end

    test "round-trips a user message with mode metadata" do
      attrs = agent_attrs("msg-user-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      message =
        {:user,
         %User{
           index: 1,
           parts: [%Part.Text{text: "[mode: chat]\nHello"}],
           metadata: %{"mode" => "chat"}
         }}

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.name, message)
      assert row.role == "user"
      assert row.message_index == 1
      assert row.metadata == %{"mode" => "chat"}
    end

    test "round-trips an assistant message with multiple parts (text + thinking + tool_use)" do
      attrs = agent_attrs("msg-assistant-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

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

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.name, message)

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
      {:ok, _} = Persistence.insert_agent(attrs)

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

      assert {:ok, %PersistedMessage{} = row} = Persistence.insert_message(attrs.name, message)
      assert row.role == "tool"

      assert %{"parts" => [r1, r2]} = row.content
      assert r1["kind"] == "tool_result"
      assert r1["toolCallId"] == "call_1"
      assert r2["isError"] == true
    end

    test "returns :agent_not_found for an unknown name" do
      message = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "hi"}]}}

      assert {:error, :agent_not_found} =
               Persistence.insert_message(
                 "never-seen-#{Elixir.System.unique_integer([:positive])}",
                 message
               )
    end
  end

  describe "insert_message/2 idempotency" do
    # Regression for the /agent/defeated-jackal crash: when the
    # Agent's `init/1` re-inserts the initial system message at
    # index 0, the unique constraint on (agent_id, message_index)
    # would fire. `on_conflict: :nothing` makes the insert a
    # silent no-op so the restore path doesn't crash. The
    # `PersistedMessage.changeset/2` declares the constraint so
    # any future caller without `on_conflict` gets a Changeset
    # error instead of a raised exception.
    test "is a no-op when a row at the same (agent_id, message_index) already exists" do
      attrs = agent_attrs("dup-msg-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      original =
        {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "original prompt"}]}}

      assert {:ok, first} = Persistence.insert_message(attrs.name, original)
      first_id = first.id

      duplicate =
        {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "different prompt"}]}}

      assert {:ok, %PersistedMessage{id: nil}} =
               Persistence.insert_message(attrs.name, duplicate)

      assert [%PersistedMessage{id: ^first_id}] =
               Nest.Repo.all(PersistedMessage)
    end

    test "is idempotent across the full Agent.init/1 restore path" do
      attrs = agent_attrs("restore-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      system_msg = {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
      assert {:ok, _} = Persistence.insert_message(attrs.name, system_msg)

      second_call = fn ->
        Persistence.insert_message(attrs.name, system_msg)
      end

      assert {:ok, _} = second_call.()
    end
  end

  describe "load_messages/1" do
    test "returns every message in message_index order, including compaction markers" do
      attrs = agent_attrs("load-all-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:system, %MsgSystem{index: 0, parts: [%Part.Text{text: "sys"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "hello"}]}}
        )

      assert {:ok, marker} = Persistence.record_compaction(attrs.name, 3, 3)
      assert marker.message_index == 3

      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:user, %User{index: 4, parts: [%Part.Text{text: "post-marker"}]}}
        )

      messages = Persistence.load_messages(attrs.name)
      assert length(messages) == 5
      assert Enum.map(messages, fn {_, %{index: idx}} -> idx end) == [0, 1, 2, 3, 4]

      assert Enum.map(messages, fn {role, _} -> role end) == [
               :system,
               :user,
               :assistant,
               :compaction,
               :user
             ]
    end

    test "round-trip preserves parts (text + thinking + tool_use)" do
      attrs = agent_attrs("load-roundtrip-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

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

      assert {:ok, _} = Persistence.insert_message(attrs.name, original)

      [{:assistant, restored}] = Persistence.load_messages(attrs.name)
      assert restored.parts == original_parts
      assert restored.usage == %{"input_tokens" => 10}
      assert restored.finish_reason == "tool_calls"
    end

    test "empty agent returns empty list" do
      assert Persistence.load_messages("load-empty-#{Elixir.System.unique_integer([:positive])}") ==
               []
    end
  end

  describe "record_compaction/3" do
    test "inserts a compaction marker row at marker_index and bumps last_compaction_index" do
      attrs = agent_attrs("record-#{Elixir.System.unique_integer([:positive])}")
      {:ok, %PersistedAgent{id: agent_id}} = Persistence.insert_agent(attrs)

      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:user, %User{index: 0, parts: [%Part.Text{text: "First"}]}}
        )

      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:assistant, %Assistant{index: 1, parts: [%Part.Text{text: "Reply"}]}}
        )

      assert {:ok, %PersistedMessage{} = marker} =
               Persistence.record_compaction(attrs.name, 2, 2)

      assert marker.role == "compaction"
      assert marker.message_index == 2
      assert marker.compaction_archived_count == 2
      assert marker.compaction_occurred_at != nil

      agent_row = Nest.Repo.one!(from(a in PersistedAgent, where: a.id == ^agent_id))

      assert agent_row.last_compaction_index == 2
      assert Nest.Repo.all(PersistedMessage) |> length() == 3
    end

    test "rolls back the column bump when the marker INSERT fails" do
      attrs = agent_attrs("rollback-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      # Pre-insert a row at the marker index to force a unique
      # constraint violation.
      {:ok, _} =
        Persistence.insert_message(
          attrs.name,
          {:system, %MsgSystem{index: 5, parts: [%Part.Text{text: "collision"}]}}
        )

      assert {:error, _reason} = Persistence.record_compaction(attrs.name, 5, 0)

      assert {:ok, -1} = Persistence.last_compaction_index(attrs.name)
    end

    test "advances the boundary across multiple compactions" do
      attrs = agent_attrs("multi-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      assert {:ok, _} = Persistence.record_compaction(attrs.name, 5, 0)
      assert {:ok, _} = Persistence.record_compaction(attrs.name, 12, 0)
      assert {:ok, _} = Persistence.record_compaction(attrs.name, 20, 0)

      assert {:ok, 20} = Persistence.last_compaction_index(attrs.name)
    end
  end

  describe "last_compaction_index/1" do
    test "returns -1 for fresh agents" do
      attrs = agent_attrs("fresh-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)
      assert {:ok, -1} = Persistence.last_compaction_index(attrs.name)
    end

    test "returns the boundary after a record_compaction" do
      attrs = agent_attrs("post-compact-#{Elixir.System.unique_integer([:positive])}")
      {:ok, _} = Persistence.insert_agent(attrs)

      assert {:ok, _marker} = Persistence.record_compaction(attrs.name, 7, 5)
      assert {:ok, 7} = Persistence.last_compaction_index(attrs.name)
    end

    test "returns :agent_not_found for an unknown name" do
      assert {:error, :agent_not_found} =
               Persistence.last_compaction_index(
                 "missing-#{Elixir.System.unique_integer([:positive])}"
               )
    end
  end
end
