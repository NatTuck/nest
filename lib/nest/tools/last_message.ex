defmodule Nest.Tools.LastMessage do
  @moduledoc """
  The `agents-last-message` tool spec (issue #62).

  The explicit content fetch that replaces the payload `agents-wait` used to
  carry: it pulls the pending delivered message from a named agent out of the
  caller's own inbox, mid-turn, and consumes it so the turn-boundary drain
  cannot deliver it a second time.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_last_message/2`, which delegates to
  `Nest.Agents.Agent.LastMessage` in the turn's tool worker (never the calling
  agent's GenServer).
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-last-message` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-last-message",
      description:
        "Read the message a named agent has delivered to you and is waiting to " <>
          "be delivered (the body of its completed turn, or its reply to your " <>
          "query). Call this mid-turn to act on a result without ending your " <>
          "turn. The message is consumed: it will not be delivered again at your " <>
          "next turn boundary. Returns that there is nothing pending when the " <>
          "agent has no undelivered message for you. Use `agents-wait` " <>
          "first to know when the agent has finished.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the agent whose message to read."
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["name"]
      },
      function: fn _args, _context ->
        {:ok, "Last message request received."}
      end
    }
  end
end
