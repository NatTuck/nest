defmodule Nest.Tools.Groups do
  @moduledoc """
  Tool capability groups.

  A vocation's `tools` field holds group names rather than individual
  tool names. This module is the single source of truth for the mapping
  from a group to the concrete tools it grants, and for expanding a list
  of groups into the individual tool names the rest of the pipeline
  (`Nest.Agents.Agent.SystemPrompt`, `Nest.Tools.get_functions/3`, the
  BatchSizer, ...) already works with.

  Groups:

    * `"file"`    — read/write/edit/inspect files
    * `"shell"`   — run shell commands, including background jobs
    * `"context"` — context usage/compaction control tools
    * `"agents"`  — spawn/query/archive sub-agents and list models
  """

  require Logger

  @groups %{
    "file" => ~w(file-read file-write file-edit file-inspect),
    "shell" => ~w(shell-cmd shell-list shell-wait shell-kill),
    "context" => ~w(context-check context-compact),
    "agents" =>
      ~w(agents-spawn agents-query agents-send agents-wait agents-list agents-archive agents-batch models-list)
  }

  # Canonical order. Expansion follows this order (and the tool order
  # within each group) so an agent's tool list — and therefore its tool
  # schemas in the LLM request — is deterministic.
  @group_order ~w(file shell context agents)

  @doc "All known group names, in canonical order."
  @spec all() :: [String.t()]
  def all, do: @group_order

  @doc "The concrete tools granted by a single group (`[]` when unknown)."
  @spec tools_for(String.t()) :: [String.t()]
  def tools_for(group), do: Map.get(@groups, group, [])

  @doc "Whether `group` is a known group name."
  @spec group?(String.t()) :: boolean()
  def group?(group), do: Map.has_key?(@groups, group)

  @doc """
  Expand a list of group names into individual tool names, deduped and
  in canonical order. Unknown entries are logged and dropped.
  """
  @spec expand([String.t()]) :: [String.t()]
  def expand(groups) when is_list(groups) do
    requested = groups |> Enum.filter(&known?/1) |> MapSet.new()

    Enum.flat_map(all(), fn group ->
      if MapSet.member?(requested, group), do: tools_for(group), else: []
    end)
  end

  defp known?(group) do
    if group?(group) do
      true
    else
      Logger.warning("Unknown tool group #{inspect(group)}; skipped")
      false
    end
  end
end
