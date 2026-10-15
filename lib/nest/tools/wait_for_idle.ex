defmodule Nest.Tools.WaitForIdle do
  @moduledoc """
  The `agents-wait` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, and
  `ShellJobs`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_wait_for_idle/2`, which registers a watch
  (`Nest.Agents.Agent.Watch`) and returns immediately. The call never waits on
  the caller's side (issue #54): when there is something to wait for, the watch
  is what the machine reads off the result (`state: "waiting"`) to end the
  caller's turn, and the notice it delivers is what wakes the idle agent.

  This tool is **synchronisation only** (issue #62): it never carries the
  watched agent's message. The body comes from the inbox delivery, or from
  `agents-last-message` when the caller needs it mid-turn.
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-wait` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-wait",
      description:
        "Wait for peer agents in this space to finish their turns, and report " <>
          "which are idle and which are still busy. Pass a list of agent names, " <>
          "or an empty list for every other agent in this workspace. " <>
          "This call returns immediately and, when there is something to wait " <>
          "for, ends your turn: you go idle and are woken by a message when the " <>
          "agents go idle. Nothing waits for them on your side — put anything " <>
          "else you want done now in this same batch, and do not poll. " <>
          "When every target is already idle, or the space holds no other " <>
          "agent, there is nothing to watch: the partition is reported in this " <>
          "result and your turn continues. `timeout` bounds the watch, not the " <>
          "call — reaching it is a normal result, delivered as a message, not " <>
          "an error. Pass `all: true` to wait for every named agent rather " <>
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
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Maximum milliseconds to watch for the agents to go idle. " <>
                "Defaults to 300000 (5 minutes). Reaching it is a normal " <>
                "result, delivered as a message, not an error."
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
