defmodule Nest.Tools.QueryAgent do
  @moduledoc """
  The `agents-query` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, `ShellJobs`,
  and `WaitAgents`) so `Nest.Tools`'s own functions stay small.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_query_agent/2`, which delivers the
  message to the target via `Agent.deliver_message/4` and reports the
  delivery disposition. Nothing waits: the target owes the caller a
  reply, and that reply arrives later as an ordinary message in the
  caller's inbox — or, if the target never answers, as a runtime notice
  saying so.
  """

  alias Nest.LLM.Tool

  @doc """
  The `agents-query` `Nest.LLM.Tool` struct.
  """
  @spec function() :: Tool.t()
  def function do
    %Tool{
      name: "agents-query",
      description:
        "Send a chat message to another agent in this space and mark that it " <>
          "owes you a reply. Nothing waits: this call returns as soon as the " <>
          "message is delivered (or immediately reports why it could not be " <>
          "delivered), and the target's answer arrives later as a message in " <>
          "your inbox. The target owes the reply, so it stays in its turn " <>
          "until it answers rather than going idle; if it never answers, the " <>
          "runtime gives up and sends you a notice saying so instead. Use " <>
          "this to delegate a question to a specialist you have already " <>
          "spawned (see `agents-spawn` and `agents-list`). Use `agents-wait` " <>
          "to wait for the peer to finish, and `agents-send` to reply to a " <>
          "peer that queried you.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the agent to query."
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The message to send to that agent."
          }
        },
        "required" => ["name", "prompt"]
      },
      function: fn _args, _context ->
        {:ok, "Query agent request received."}
      end
    }
  end
end
