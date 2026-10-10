defmodule Nest.Tools.SpawnAgent do
  @moduledoc """
  The `agents-spawn` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, `ShellJobs`,
  and `WaitAgents`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_spawn_agent/2`, which sends a
  `:spawn_agent_request` to the coordinator GenServer. Nothing waits: a
  `query` is delivered to the new agent and its turn-final answer — or,
  for a child that fails, is stopped or produces nothing, a runtime
  notice naming the reason — arrives later as a message in the caller's
  inbox.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.LLM.Tool

  @doc """
  The `agents-spawn` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-spawn",
      description: description(),
      parameters_schema: schema(),
      function: fn _args, _context ->
        {:ok, "Spawn agent request received."}
      end
    }
  end

  defp description do
    "Create a sub-agent in this space and optionally delegate a task to it. " <>
      "Returns the new agent's name; if `query` is given, the task is " <>
      "delivered to the new agent and its answer arrives later as a message " <>
      "in your inbox — or, for a child that fails, is stopped or produces " <>
      "nothing, a runtime notice naming the reason instead. Nothing waits: " <>
      "the spawn is confirmed right away (a bad spawn still comes back as an " <>
      "error you can fix). `vocation` (a slug like \"programmer\") defaults " <>
      "to your own vocation (or the space's sole allowed vocation when your " <>
      "own isn't allowed) — set it to spawn a specialist with a different " <>
      "role. Set `clone_context` to true to spawn the agent with a copy of " <>
      "this conversation instead of a fresh context. Set `archive` to true " <>
      "(with `query`) to stop and archive the agent after it responds " <>
      "(one-shot). Use `agents-wait` to wait for the new agent to finish. " <>
      "Spawned vocations may be restricted by this space's blueprint. " <>
      "Sub-agents can be spawned down to a maximum depth of " <>
      "#{Config.configured_max_depth()}. Set `model` to a " <>
      "\"provider/model-name\" string (e.g. as returned by `models-list`) " <>
      "to spawn the child on a specific model; it inherits your own model " <>
      "when omitted."
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "The unique name of the new sub-agent within this space."
        },
        "vocation" => %{
          "type" => "string",
          "description" =>
            "The vocation slug defining the specialist's role and tools " <>
              "(for example \"programmer\"). Defaults to your own " <>
              "vocation when omitted (or the space's sole allowed vocation if " <>
              "your own isn't allowed)."
        },
        "clone_context" => %{
          "type" => "boolean",
          "description" =>
            "When true, spawn the agent with a copy of this conversation " <>
              "instead of a fresh context."
        },
        "query" => %{
          "type" => "string",
          "description" =>
            "When given, sends this as the agent's first task. The task is " <>
              "delivered immediately and the agent's answer arrives later as " <>
              "a message in your inbox — or, for a child that fails, is " <>
              "stopped or produces nothing, a runtime notice naming the " <>
              "reason."
        },
        "archive" => %{
          "type" => "boolean",
          "description" =>
            "When true (with `query`), stop and archive the agent after it " <>
              "responds. Makes the spawn one-shot."
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "The model for the new sub-agent as a \"provider/model-name\" string " <>
              "(see `models-list`). Inherits your own model when omitted."
        }
      },
      "required" => ["name"]
    }
  end
end
