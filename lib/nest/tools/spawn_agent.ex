defmodule Nest.Tools.SpawnAgent do
  @moduledoc """
  The `agents-spawn` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, `ShellJobs`,
  and `WaitAgents`) because `Nest.Tools` is at the source-file line cap.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_spawn_agent/2`, which sends a
  `:spawn_agent_request` to the coordinator GenServer. With `async: true`
  the call returns immediately and a supervised waiter
  (`Nest.Agents.Agent.AsyncWaiter`) delivers the outcome to the caller's
  inbox as a message.
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
      "Returns the new agent's name; if `query` is given, additionally blocks " <>
      "and returns the agent's response. `vocation` (a slug like " <>
      "\"programmer\") defaults to your own " <>
      "vocation (or the space's sole allowed vocation when your own isn't " <>
      "allowed) — set it to spawn a specialist with a different role. Set " <>
      "`clone_context` to true to spawn the agent with a copy of this " <>
      "conversation instead of a fresh context. Set `archive` to true (with " <>
      "`query`) to stop and archive the agent after it responds (one-shot). " <>
      "Set `async` to true (with `query`) to return immediately instead of " <>
      "blocking: the spawn is confirmed right away (a bad spawn still comes " <>
      "back as an error you can fix) and the agent's response arrives later " <>
      "as a message in your inbox, prefixed `[agents-spawn result]` (or " <>
      "`[agents-spawn failed]` / `[agents-spawn timed out]`). A Stop does " <>
      "not cancel the waiter, so the eventual message may be a timeout " <>
      "notice, and a refused delivery (a broken caller status or a full " <>
      "inbox) loses the result. Use `agents-wait` to wait for it. " <>
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
            "When given, sends this as the agent's first task. By default " <>
              "the call blocks for its response; set `async` to return " <>
              "immediately and receive the response later as a message."
        },
        "async" => %{
          "type" => "boolean",
          "description" =>
            "When true (with `query`), return immediately and deliver the " <>
              "agent's response later as a message in your inbox, prefixed " <>
              "`[agents-spawn result]` (or `[agents-spawn failed]` / " <>
              "`[agents-spawn timed out]`). Use `agents-wait` to wait for it. " <>
              "Defaults to false.",
          "default" => false
        },
        "archive" => %{
          "type" => "boolean",
          "description" =>
            "When true (with `query`), stop and archive the agent after it " <>
              "responds. Makes the spawn one-shot."
        },
        "timeout" => %{
          "type" => "integer",
          "description" =>
            "Maximum milliseconds to wait for the response (with `query`, " <>
              "blocking or async). Defaults to 300000 (5 minutes)."
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "The model for the new sub-agent as a \"provider/model-name\" string " <>
              "(see `models-list`). Inherits your own model when omitted."
        },
        "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
      },
      "required" => ["name"]
    }
  end
end
