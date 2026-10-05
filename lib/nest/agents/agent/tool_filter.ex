defmodule Nest.Agents.Agent.ToolFilter do
  @moduledoc """
  Depth-based tool filtering.

  An agent at the configured maximum spawn depth must not be offered the
  sub-agent spawn tools. This is applied at three points:

    * `Nest.Agents.Agent.Init` — at startup, for non-clone children
      (via the `:exclude_spawn` attr; clones keep the parent's exact
      tool list per the clone rule).
    * `Nest.Agents.Agent.WorkspaceHandler` — when the workspace changes
      and the tool list is rebuilt.
    * `Nest.Agents.Agent.Machine.Compaction` — on compaction
      (which invalidates the prefix cache, so the list may change).

  Keeping the map from depth → filter here means the spawn and
  workspace paths cannot drift from each other.
  """

  alias Nest.Agents.Agent.Config

  # Tools that let an agent delegate to (or fan out over) sub-agents.
  @spawn_tools ~w(agents-spawn agents-batch)

  @doc """
  Drop the spawn tools from `tool_names` when `depth` is at or past the
  configured maximum. Returns the list unchanged below that depth.
  """
  @spec exclude_spawn_at_max_depth([String.t()], non_neg_integer()) :: [String.t()]
  def exclude_spawn_at_max_depth(tool_names, depth) do
    if depth >= Config.configured_max_depth() do
      Enum.reject(tool_names, &(&1 in @spawn_tools))
    else
      tool_names
    end
  end
end
