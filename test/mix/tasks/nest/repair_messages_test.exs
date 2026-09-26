defmodule Mix.Tasks.Nest.RepairMessagesTest do
  @moduledoc """
  Exercises the `mix nest.repair_messages` wrapper end to end:
  dry-run raises on violations, `--apply` repairs and exits clean,
  and bad input raises.

  `async: false` is required: `Mix.Shell.Process` is a global
  swap, so these tests must not run concurrently with each other or
  with any other test that prints through `Mix.shell/0`.
  """

  use Nest.DataCase, async: false

  import Nest.PersistenceTestHelpers

  alias Mix.Tasks.Nest.RepairMessages
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  test "dry-run raises on violations and --apply repairs" do
    space_id = test_space_id()
    name = unique_name("cli-root")
    {:ok, _} = Persistence.insert_agent(agent_attrs(name))

    insert_messages(space_id, name, [
      system(0),
      user(1, "run it"),
      assistant_tool(2, "call_1")
    ])

    assert_raise Mix.Error, ~r/violations found/, fn -> RepairMessages.run(["--all"]) end
    assert_received {:mix_shell, :info, [report]}
    assert report =~ "Violations found"

    assert :ok = RepairMessages.run(["--all", "--apply", "--verbose"])
    assert_received {:mix_shell, :info, [applied_report]}
    assert applied_report =~ "Planned writes"

    assert :ok = RepairMessages.run(["--all"])
  end

  test "missing or bad targets raise" do
    assert_raise Mix.Error, ~r/specify --space/, fn -> RepairMessages.run([]) end

    assert_raise Mix.Error, ~r/repair failed/, fn ->
      RepairMessages.run(["--space", "does-not-exist"])
    end
  end

  # ---- helpers ----

  defp insert_messages(space_id, name, messages) do
    for message <- messages do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end
  end

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index, text), do: {:user, %User{index: index, parts: [%Part.Text{text: text}]}}

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
