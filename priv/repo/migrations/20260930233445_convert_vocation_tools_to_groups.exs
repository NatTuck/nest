defmodule Nest.Repo.Migrations.ConvertVocationToolsToGroups do
  use Ecto.Migration

  import Ecto.Query

  # Self-contained copy of the individual-tool → group mapping. Kept
  # local (rather than referencing `Nest.Tools.Groups`) so this
  # migration remains correct even if the application's group
  # definitions change later.
  @group_order ~w(file shell context agents)

  @tool_to_group %{
    "file-read" => "file",
    "file-write" => "file",
    "file-edit" => "file",
    "file-inspect" => "file",
    "shell-cmd" => "shell",
    "shell-list" => "shell",
    "shell-wait" => "shell",
    "shell-kill" => "shell",
    "context-check" => "context",
    "context-compact" => "context",
    "agents-spawn" => "agents",
    "agents-query" => "agents",
    "agents-list" => "agents",
    "agents-archive" => "agents",
    "agents-batch" => "agents",
    "models-list" => "agents",
    # Pre-rename name, still injected by
    # 20260718201841_add_clone_agent_to_vocations.
    "clone_agent" => "agents"
  }

  @group_to_tools %{
    "file" => ~w(file-read file-write file-edit file-inspect),
    "shell" => ~w(shell-cmd),
    "context" => ~w(context-check context-compact),
    "agents" => ~w(agents-spawn agents-query agents-list agents-archive agents-batch models-list)
  }

  def up do
    flush()

    all_vocation_tools()
    |> Enum.each(fn {id, tools} -> update_tools(id, to_groups(tools)) end)
  end

  def down do
    flush()

    all_vocation_tools()
    |> Enum.each(fn {id, groups} -> update_tools(id, to_tools(groups)) end)
  end

  defp all_vocation_tools do
    repo().all(from(v in "vocations", select: {v.id, v.tools}))
  end

  # Map every entry to its group (recognizing entries that are already
  # group names), drop anything unknown, dedupe, and order canonically.
  defp to_groups(tools) do
    mapped =
      tools
      |> Enum.map(&Map.get(@tool_to_group, &1, &1))
      |> Enum.filter(&(&1 in @group_order))
      |> MapSet.new()

    Enum.filter(@group_order, &MapSet.member?(mapped, &1))
  end

  defp to_tools(groups) do
    Enum.flat_map(groups, &Map.get(@group_to_tools, &1, []))
  end

  defp update_tools(id, tools) do
    repo().update_all(from(v in "vocations", where: v.id == ^id), set: [tools: tools])
  end
end
