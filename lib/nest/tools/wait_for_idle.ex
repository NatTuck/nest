defmodule Nest.Tools.WaitForIdle do
  @moduledoc """
  The `agents-wait-for-idle` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, and
  `ShellJobs`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_wait_for_idle/2`, which either runs the
  blocking wait (`Nest.Agents.Agent.WaitForIdle`) in the turn's tool worker or
  registers a watch (`Nest.Agents.Agent.Watch`) and returns immediately.

  This tool is **synchronisation only** (issue #62): it never carries the
  watched agent's message. The body comes from the inbox delivery, or from
  `agents-last-message` when the caller needs it mid-turn.
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-wait-for-idle` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-wait-for-idle",
      description:
        "Wait for peer agents in this space to finish their turns, and report " <>
          "which are idle and which are still busy. Pass a list of agent names, " <>
          "or an empty list for every other agent in this workspace. " <>
          "By default this returns immediately and leaves you idle so a human " <>
          "can message you: you will be sent a notice when the agents go idle. " <>
          "Pass `block: true` to block the turn instead (the wait is then " <>
          "bounded by `timeout` milliseconds; reaching it is a normal result, " <>
          "not an error). Pass `all: true` to wait for every named agent rather " <>
          "than the first. " <>
          "This call carries NO message content — use `agents-last-message` to " <>
          "read an agent's message once it is idle. An idle peer owes no " <>
          "replies: a peer you queried does not go idle until it has answered " <>
          "you or the runtime has given up on it. A give-up reaches you as a " <>
          "runtime notice — unless the runtime cannot reach you, in which case " <>
          "it only records the refusal. Use this when you cannot continue " <>
          "until a peer has finished.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "names" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The agent names to wait for. An empty list (or omitting this " <>
                "argument) means every other agent in this workspace. The " <>
                "calling agent is never a target."
          },
          "all" => %{
            "type" => "boolean",
            "description" =>
              "When true, wait until every named agent is idle. Defaults to " <>
                "false: fire as soon as the first busy agent goes idle."
          },
          "block" => %{
            "type" => "boolean",
            "description" =>
              "When true, block this turn until the event fires instead of " <>
                "returning immediately. Defaults to false (non-blocking: you go " <>
                "idle and a notice arrives later)."
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Maximum milliseconds to wait. Defaults to 300000 (5 minutes). " <>
                "Reaching it is a normal result, not an error."
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => []
      },
      function: fn _args, _context ->
        {:ok, "Wait for agents request received."}
      end
    }
  end
end
