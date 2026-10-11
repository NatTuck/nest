defmodule Nest.Tools.ArchivedAgents do
  @moduledoc """
  The `agents-unarchive` and `agents-list-archived` tool specs.

  Kept in their own module (like `QueryAgent`, `SpawnAgent`, and
  `WaitAgents`) so `Nest.Tools`'s own functions stay small — and so
  `Nest.Tools` stays inside the file-length budget.

  The `function`s here are stubs. Real execution lives in
  `Nest.Agents.Agent.ToolLoop`: `run_unarchive_agent/2` routes through
  the parent GenServer to clear the archived flag, and
  `run_list_archived_agents/2` reads the space's archived rows.
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-unarchive` `Nest.LLM.Tool` struct.

  Restoring an agent also restores its whole archived subtree:
  archiving a parent archives its descendants, and they come back with
  it. Restoring a child whose parent is still archived is refused.
  """
  @spec unarchive_function() :: Tool.t()
  def unarchive_function do
    %Tool{
      name: "agents-unarchive",
      description:
        "Restore an archived agent in this space to the active list, along " <>
          "with its whole archived subtree (archiving a parent archives its " <>
          "descendants, and they come back with it). The agents become " <>
          "listable and queryable again (each is rehydrated on demand the " <>
          "next time it is addressed). Restoring an agent that is already " <>
          "active does nothing. Restoring a child whose parent is still " <>
          "archived is refused — restore the parent instead. Use this to " <>
          "bring back a specialist you archived with `agents-archive`.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the archived agent to restore."
          }
        },
        "required" => ["name"]
      },
      function: fn _args, _context ->
        {:ok, "Unarchive agent request received."}
      end
    }
  end

  @doc """
  The `agents-list-archived` `Nest.LLM.Tool` struct.

  Lists the archived agents in the space with their name, parent, and
  depth, so the model can find the one it wants back.
  """
  @spec list_archived_function() :: Tool.t()
  def list_archived_function do
    %Tool{
      name: "agents-list-archived",
      description:
        "List the archived agents in this space, with their name, parent, and " <>
          "depth. Use this to find an agent you (or a sibling) archived that " <>
          "you want back — restore it with `agents-unarchive`.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"max_result_tokens" => Nest.Tools.max_result_tokens_schema()},
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "List archived agents request received."}
      end
    }
  end
end
