defmodule Nest.Tools.QueryAgent do
  @moduledoc """
  The `agents-query` tool spec.

  Kept in its own module (like `FileTools`, `InspectFile`, `ShellJobs`,
  and `WaitAgents`) because `Nest.Tools` is at the source-file line cap.

  The `function` here is a stub: real execution lives in
  `Nest.Agents.Agent.ToolLoop.run_query_agent/2`, which subscribes to
  the target's PubSub topic, triggers its turn via `Agents.chat/3`, and
  waits for the idle status before returning the target's latest
  assistant text. With `async: true` the call returns immediately and a
  supervised waiter (`Nest.Agents.Agent.AsyncWaiter`) delivers the
  response to the caller's inbox as a message.
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
        "Send a chat message to a sub-agent in this space and wait for it to " <>
          "finish its current turn, returning its latest assistant text. A " <>
          "message sent to a target that is mid-turn is queued for its next " <>
          "turn, so the text returned can be the target's current turn output " <>
          "rather than a reply to your message. Use this to delegate a question " <>
          "to a specialist you have already spawned (see `agents-spawn` and " <>
          "`agents-list`). By default your turn blocks until the target " <>
          "responds; set `async` to true to return immediately instead, in " <>
          "which case the response arrives later as a message in your inbox, " <>
          "prefixed `[agents-query result]` (or `[agents-query failed]` / " <>
          "`[agents-query timed out]`). Use `agents-wait` to wait for it.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the sub-agent to query."
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The message to send to the sub-agent."
          },
          "async" => %{
            "type" => "boolean",
            "description" =>
              "When true, return immediately and deliver the target's " <>
                "response later as a message in your inbox, prefixed " <>
                "`[agents-query result]` (or `[agents-query failed]` / " <>
                "`[agents-query timed out]`). Use `agents-wait` to wait for it. " <>
                "Defaults to false.",
            "default" => false
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Maximum milliseconds to wait for the response (blocking or " <>
                "async). Defaults to 300000 (5 minutes)."
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["name", "prompt"]
      },
      function: fn _args, _context ->
        {:ok, "Query agent request received."}
      end
    }
  end
end
