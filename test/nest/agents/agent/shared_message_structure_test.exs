defmodule Nest.Agents.Agent.SharedMessageStructureTest do
  @moduledoc """
  Pins the immutable shared message structure
  (`notes/shared-message-structure.md`):

    * a clone **shares** its ancestors' rows and never copies them;
    * a clone owns only its fork rows (no system row at index 0);
    * the full sequence is reconstructed recursively via `parent_id`;
    * a restart round-trip returns exactly the same sequence;
    * a detached clone (fork cleared at compaction) owns its own rows.

  These tests drive the persistence layer directly
  (`Agent.build_child_attrs/5` + `Agent.pre_spawn/1` +
  `Persistence.load_full_messages/2`) so they don't depend on a live
  GenServer or an LLM.
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.PersistedAgent
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  describe "clone spawn + resolve" do
    test "clone owns only its fork rows; the parent rows are shared, not copied" do
      {parent_state, child_name} = spawn_clone_fixture()

      # The clone's own rows are exactly the fork (tool result +
      # ack), starting at the fork boundary, with no system row.
      own = Persistence.load_messages(parent_state.space_id, child_name)
      assert Enum.map(own, &index_of/1) == [3, 4]
      refute Enum.any?(own, &match?({:system, _}, &1))

      # The parent still owns only its original three rows.
      parent_own = Persistence.load_messages(parent_state.space_id, parent_state.name)
      assert Enum.map(parent_own, &index_of/1) == [0, 1, 2]
    end

    test "full sequence is the shared prefix followed by the clone's own rows" do
      {parent_state, child_name} = spawn_clone_fixture()

      full = Persistence.load_full_messages(parent_state.space_id, child_name)

      assert Enum.map(full, &index_of/1) == [0, 1, 2, 3, 4]

      assert Enum.map(full, fn {role, _} -> role end) == [
               :system,
               :user,
               :assistant,
               :tool,
               :assistant
             ]

      # Index 2 is the parent's real spawn assistant (shared).
      assert {:assistant, %Assistant{parts: [%Part.ToolUse{id: "call_1"}]}} = Enum.at(full, 2)

      # Index 3 is the clone's own "you are the clone" result that
      # answers the shared tool_use id.
      assert {:tool, %Tool{parts: [result]}} = Enum.at(full, 3)
      assert %Part.ToolResult{tool_call_id: "call_1", is_error: false} = result
      assert result.content =~ child_name
      assert result.content =~ "clone"

      assert :ok = Preflight.validate_tool_call_pairing(full)
    end

    test "restart round-trip reconstructs the identical full sequence" do
      {parent_state, child_name} = spawn_clone_fixture()

      live_full = Persistence.load_full_messages(parent_state.space_id, child_name)
      {:ok, attrs} = Persistence.build_attrs_for_start(parent_state.space_id, child_name)

      assert attrs.fork_message_index == 3
      assert attrs.preloaded_messages == live_full
      assert :ok = Preflight.validate_tool_call_pairing(attrs.preloaded_messages)
    end

    test "clone of a clone shares both ancestors with no duplication" do
      {parent_state, child_name} = spawn_clone_fixture()

      {:ok, child_row} = Persistence.fetch_agent(parent_state.space_id, child_name)
      child_full = Persistence.load_full_messages(parent_state.space_id, child_name)

      # The child has since been prompted and itself called
      # agents-spawn (assistant at 6, next index 7); those rows
      # are persisted by the child's live append path.
      child_messages = child_full ++ [user_message(5), spawn_assistant(6, "call_2")]

      for message <- [user_message(5), spawn_assistant(6, "call_2")] do
        {:ok, _} = Persistence.insert_message(parent_state.space_id, child_name, message)
      end

      child_state = %Agent{
        name: child_name,
        space_id: parent_state.space_id,
        model: parent_state.model,
        vocation_id: parent_state.vocation_id,
        depth: 1,
        chat_state: %Agent.ChatState{
          messages: child_messages,
          history: [],
          next_message_index: 7,
          last_compaction_index: -1
        }
      }

      grandchild_name = unique_name("grandchild")
      attrs = Agent.build_child_attrs(child_state, "sub-task", grandchild_name, child_row.id)
      assert :ok = Agent.pre_spawn(attrs)

      grandchild_own = Persistence.load_messages(parent_state.space_id, grandchild_name)
      assert Enum.map(grandchild_own, &index_of/1) == [7, 8]
      refute Enum.any?(grandchild_own, &match?({:system, _}, &1))

      grandchild_full = Persistence.load_full_messages(parent_state.space_id, grandchild_name)

      expectations = child_messages ++ grandchild_own
      assert Enum.map(grandchild_full, &index_of/1) == Enum.map(expectations, &index_of/1)
      assert roles(grandchild_full) == roles(expectations)

      assert roles(grandchild_full) == [
               :system,
               :user,
               :assistant,
               :tool,
               :assistant,
               :user,
               :assistant,
               :tool,
               :assistant
             ]

      assert :ok = Preflight.validate_tool_call_pairing(grandchild_full)
    end

    test "detached clone resolves to its own rows only" do
      {parent_state, child_name} = spawn_clone_fixture()

      assert :ok =
               Persistence.update_fork_message_index(parent_state.space_id, child_name, nil)

      {:ok, %PersistedAgent{fork_message_index: nil}} =
        Persistence.fetch_agent(parent_state.space_id, child_name)

      assert Persistence.load_full_messages(parent_state.space_id, child_name) ==
               Persistence.load_messages(parent_state.space_id, child_name)
    end
  end

  describe "fresh child" do
    test "owns a system row at index 0 and shares nothing" do
      parent_attrs = agent_attrs(unique_name("fresh-parent"))
      {:ok, %PersistedAgent{id: parent_id}} = Persistence.insert_agent(parent_attrs)

      parent_state =
        parent_state(parent_attrs, [system_message(0)], next_index: 1, depth: 0)

      child_name = unique_name("fresh-child")

      attrs =
        SubAgent.build_fresh_child_attrs(
          parent_state,
          child_name,
          parent_id,
          test_vocation_id(),
          false
        )
        |> Persistence.build_agent_attrs()

      assert :ok = Agent.pre_spawn(attrs)

      own = Persistence.load_messages(parent_attrs.space_id, child_name)
      assert Enum.map(own, &index_of/1) == [0]
      assert match?([{:system, _}], own)

      {:ok, %PersistedAgent{fork_message_index: nil}} =
        Persistence.fetch_agent(parent_attrs.space_id, child_name)

      assert Persistence.load_full_messages(parent_attrs.space_id, child_name) == own
    end
  end

  # ---- helpers ----

  # Parent mid-turn: system 0, user 1, assistant[agents-spawn] 2.
  # The real spawn assistant is the shared prefix's tail; the clone
  # owns the tool result + ack at 3 and 4.
  defp spawn_clone_fixture do
    parent_attrs = agent_attrs(unique_name("parent"))
    {:ok, %PersistedAgent{id: parent_id}} = Persistence.insert_agent(parent_attrs)

    for message <- [
          system_message(0),
          {:user, %User{index: 1, parts: [%Part.Text{text: "delegate"}]}},
          spawn_assistant(2)
        ] do
      {:ok, _} = Persistence.insert_message(parent_attrs.space_id, parent_attrs.name, message)
    end

    parent_state =
      parent_state(
        parent_attrs,
        [system_message(0), user_message(1), spawn_assistant(2)],
        next_index: 3,
        depth: 0
      )

    child_name = unique_name("clone")
    attrs = Agent.build_child_attrs(parent_state, "compute", child_name, parent_id)
    assert :ok = Agent.pre_spawn(attrs)

    {parent_state, child_name}
  end

  defp parent_state(attrs, messages, opts) do
    %Agent{
      name: attrs.name,
      space_id: attrs.space_id,
      model: attrs.model,
      vocation_id: attrs.vocation_id,
      depth: Keyword.fetch!(opts, :depth),
      chat_state: %Agent.ChatState{
        messages: messages,
        history: [],
        next_message_index: Keyword.fetch!(opts, :next_index),
        last_compaction_index: -1
      }
    }
  end

  defp spawn_assistant(index, id \\ "call_1") do
    {:assistant,
     %Assistant{
       index: index,
       parts: [
         %Part.ToolUse{id: id, name: "agents-spawn", arguments: %{"query" => "compute"}}
       ],
       api_logs: []
     }}
  end

  defp system_message(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user_message(index) do
    {:user, %User{index: index, parts: [%Part.Text{text: "delegate"}]}}
  end

  defp index_of({_role, %{index: idx}}), do: idx

  defp roles(messages), do: Enum.map(messages, fn {role, _} -> role end)

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
