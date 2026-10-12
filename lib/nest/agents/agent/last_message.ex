defmodule Nest.Agents.Agent.LastMessage do
  @moduledoc """
  Executor for the `agents-last-message` tool (issue #62).

  Runs in the turn's tool worker (never the calling agent's GenServer), so it
  is callable mid-turn. It asks the caller's own GenServer for the newest
  pending delivery from `name` — the body of that agent's completed turn, or
  its reply — and the caller marks it retrieved. That is the consume half of
  the split: the turn-boundary drain will not deliver the same body again.

  The fetch reads the caller's inbox rather than the target's transcript on
  purpose. Requirement 1 (idle implies delivered) means that once
  `agents-wait-for-idle` reports an agent idle, its delivery is already in the
  caller's inbox; the fetch is exactly "receive that inbox copy mid-turn",
  which needs no second content channel and no correlation id threaded through
  the delivery path.
  """

  alias Nest.Messages.ToolCall

  # A call into the caller's own GenServer, which is free while its tool worker
  # runs. Bounded so a wedged caller cannot hang the worker.
  @call_timeout 5_000

  @doc """
  Run one `agents-last-message` call. Returns `{:ok, content}` (a body or a
  "nothing pending" result) or `{:error, content}` for a missing argument.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, %ToolCall{} = tc) do
    case extract_name(tc) do
      "" -> {:error, "Missing required argument: name."}
      name -> fetch(ctx, name)
    end
  end

  defp fetch(ctx, name) do
    case GenServer.call(ctx.agent_pid, {:last_message, name}, @call_timeout) do
      {:ok, content, id} -> {:ok, render(name, id, content)}
      :none -> {:ok, "No undelivered message from agent #{name}."}
    end
  end

  # The body plus its delivery id, so a caller can recognise a copy it already
  # has (issue #62 requirement 4).
  defp render(name, id, content) do
    "Message from agent \"#{name}\" (delivery #{id}):\n#{content}"
  end

  defp extract_name(%ToolCall{arguments: args}) when is_map(args) do
    case Map.get(args, "name") do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp extract_name(_tc), do: ""
end
