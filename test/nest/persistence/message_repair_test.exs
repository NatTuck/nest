defmodule Nest.Persistence.MessageRepairTest do
  @moduledoc """
  End-to-end tests for the offline repair tool
  (`mix nest.repair_messages`): a root orphan mirroring
  `visual-possum-root`, a simple alternation repair, and a clone
  whose fork boundary shifts with a parent-prefix insert.
  """

  use Nest.DataCase, async: true

  import Nest.PersistenceTestHelpers

  alias Mix.Tasks.Nest.RepairMessages
  alias Nest.Agents.PersistedAgent
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Persistence.MessageRepair
  alias Nest.Spaces

  describe "visual-possum root orphan" do
    test "dry-run reports, --apply repairs and is idempotent" do
      space_id = test_space_id()
      name = unique_name("root")

      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      insert_messages(space_id, name, [
        system(0),
        user(1, "run the command"),
        assistant_tool(2, "call_00_YeumRvjanX23oPG1S93n4024"),
        user(3, "still there?")
      ])

      {:ok, plan, agents} = MessageRepair.run(:all, apply: false)

      assert MessageRepair.violations?(plan)
      refute MessageRepair.residual?(plan)
      assert Enum.map(plan.inserts, & &1.index) == [3, 4]
      assert MessageRepair.format_report(plan, agents) =~ "Violations found"
      assert MessageRepair.format_report(plan, agents) =~ name

      assert {:ok, applied, _agents} = MessageRepair.run(:all, apply: true)
      refute MessageRepair.residual?(applied)

      full = Persistence.load_full_messages(space_id, name)
      assert roles(full) == [:system, :user, :assistant, :tool, :assistant, :user]
      assert Enum.map(full, &index/1) == [0, 1, 2, 3, 4, 5]
      assert :ok = Preflight.validate(full)

      assert {:tool, %Tool{parts: [%Part.ToolResult{is_error: true}]}} = Enum.at(full, 3)

      {:ok, again, _agents} = MessageRepair.run(:all, apply: false)
      refute MessageRepair.violations?(again)
      assert again.inserts == []

      assert {:ok, %PersistedAgent{next_message_index: 6}} =
               Persistence.fetch_agent(space_id, name)
    end
  end

  describe "alternation only" do
    test "two user messages are separated by a synthetic assistant" do
      space_id = test_space_id()
      name = unique_name("alt")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      insert_messages(space_id, name, [system(0), user(1, "one"), user(2, "two")])

      assert {:ok, _plan, _agents} = MessageRepair.run(:all, apply: true)

      full = Persistence.load_full_messages(space_id, name)
      assert roles(full) == [:system, :user, :assistant, :user]
      assert :ok = Preflight.validate(full)
    end
  end

  describe "clone renumbering" do
    test "a parent-prefix insert shifts the child fork and own indices" do
      space_id = test_space_id()
      parent = unique_name("clone-parent")
      child = unique_name("clone-child")

      parent_attrs = agent_attrs(parent) |> Map.put(:next_message_index, 4)
      {:ok, %PersistedAgent{id: parent_id}} = Persistence.insert_agent(parent_attrs)

      insert_messages(space_id, parent, [
        system(0),
        user(1, "one"),
        user(2, "two"),
        assistant_tool(3, "spawn-call")
      ])

      child_attrs =
        agent_attrs(child)
        |> Map.put(:parent_id, parent_id)
        |> Map.put(:fork_message_index, 4)
        |> Map.put(:next_message_index, 6)

      {:ok, _} = Persistence.insert_agent(child_attrs)

      insert_messages(space_id, child, [
        tool_result(4, "spawn-call"),
        assistant_text(5)
      ])

      assert {:ok, plan, _agents} = MessageRepair.run(:all, apply: true)
      refute MessageRepair.residual?(plan)

      assert {:ok, %PersistedAgent{fork_message_index: 5, next_message_index: 7}} =
               Persistence.fetch_agent(space_id, child)

      own = Persistence.load_messages(space_id, child)
      assert Enum.map(own, &index/1) == [5, 6]

      full = Persistence.load_full_messages(space_id, child)
      assert :ok = Preflight.validate(full)
      assert Enum.map(full, &index/1) == [0, 1, 2, 3, 4, 5, 6]
    end
  end

  describe "space targeting" do
    test "loads by space name and reports a missing space" do
      space_id = test_space_id()
      name = unique_name("space-target")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      insert_messages(space_id, name, [
        system(0),
        user(1, "one"),
        user(2, "two")
      ])

      space_name = Spaces.get_space(space_id).name

      assert {:ok, plan, agents} = MessageRepair.run({:space, space_name}, [])
      assert MessageRepair.violations?(plan)
      assert MessageRepair.format_report(plan, agents, true) =~ "Planned writes"

      assert {:error, {:space_not_found, "nope"}} = MessageRepair.run({:space, "nope"}, [])
    end
  end

  describe "CLI argument parsing" do
    test "validates targets, switches and flags" do
      assert {:error, message} = parse([])
      assert message =~ "--space"

      assert {:error, message} = parse(["--space", "s", "--all"])
      assert message =~ "not both"

      assert {:error, message} = parse(["--space", "s", "--wat"])
      assert message =~ "--wat"

      assert {:ok, {:space, "clever-raven"}, [apply: true, verbose: true]} =
               parse(["--space", "clever-raven", "--apply", "--verbose"])

      assert {:ok, :all, [apply: false, verbose: false]} = parse(["--all"])
    end
  end

  # ---- helpers ----

  defp parse(args), do: RepairMessages.parse_args(args)

  defp insert_messages(space_id, name, messages) do
    for message <- messages do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end
  end

  defp index({_role, %{index: idx}}), do: idx
  defp roles(messages), do: Enum.map(messages, fn {role, _} -> role end)

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index, text), do: {:user, %User{index: index, parts: [%Part.Text{text: text}]}}

  defp assistant_text(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end

  defp tool_result(index, id) do
    {:tool,
     %Tool{
       index: index,
       parts: [
         %Part.ToolResult{tool_call_id: id, name: "shell-cmd", content: "ok", is_error: false}
       ],
       api_logs: []
     }}
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
