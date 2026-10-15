defmodule Nest.Tools.Status do
  @moduledoc """
  The `agents-status` tool spec (issue #22).

  Kept in its own module (like `FileTools`, `InspectFile`, `ShellJobs`, and
  `WaitForIdle`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.Status.run/2`, which the turn's tool worker reaches through
  `Nest.Agents.Agent.ToolLoop.run_status/2`. It reads the target's row plus its
  live public info when it has a process, and never starts one.
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-status` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-status",
      description:
        "Report an agent's status in this space (default: yourself): its current " <>
          "state, how many messages its history holds (and so the valid index " <>
          "range for `agents-history`), the index of its last compaction, its " <>
          "model, vocation and depth, and — when it has a live process — the " <>
          "replies it owes, how many messages are queued in its inbox, and its " <>
          "context limit. It reads persisted state, so it also works for an agent " <>
          "with no live process (reported as `not_running`) and never starts one. " <>
          "An archived agent is refused (restore it with `agents-unarchive` first).",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The agent whose status to report. Defaults to you."
          }
        },
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "Status request received."}
      end
    }
  end
end
