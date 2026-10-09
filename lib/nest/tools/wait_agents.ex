defmodule Nest.Tools.WaitAgents do
  @moduledoc """
  The `agents-wait` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, and
  `ShellJobs`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_wait_agents/2`, which delegates to
  `Nest.Agents.Agent.WaitLoop` in the turn's tool worker (never the
  calling agent's GenServer).
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
        "Wait for peer agents in this space to finish their turns. Pass a " <>
          "list of agent names, or an empty list for every other agent in " <>
          "this workspace. Returns immediately if all of them are already " <>
          "idle; otherwise it returns as soon as the first busy agent goes " <>
          "idle, with that agent's name and the final message of its turn. " <>
          "An idle peer owes no replies: a peer you queried does not go idle " <>
          "until it has answered you or the runtime has given up on it. A " <>
          "give-up reaches you as a runtime notice — unless the runtime cannot " <>
          "reach you, in which case it only records the refusal. " <>
          "The wait is bounded by `timeout` (milliseconds); reaching it is a " <>
          "normal result, not an error. Use this when you cannot continue " <>
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
