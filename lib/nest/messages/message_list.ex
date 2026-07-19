defmodule Nest.Messages.MessageList do
  @moduledoc """
  Pure functions on message lists. Extracted from
  `Nest.Agents.Agent.ChatTurn.Iteration` so the compactor
  and subagent paths can share the same utilities without
  importing iteration-internal functions.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  @doc """
  Drop the trailing message if it's an assistant message
  whose parts include a `Part.ToolUse` (an unsatisfied
  tool call — Anthropic's `(2013)` validation rejects
  unpaired `tool_use`).
  """
  @spec drop_trailing_unpaired_tool_call([term()]) :: [term()]
  def drop_trailing_unpaired_tool_call(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        if Enum.any?(parts, &match?(%Part.ToolUse{}, &1)) do
          Enum.drop(messages, -1)
        else
          messages
        end

      _ ->
        messages
    end
  end

  @doc """
  Return the Anthropic wire role of the last non-system,
  non-compaction message. Used to decide whether a synthetic
  assistant bridge is needed before appending a new user message.
  """
  @spec last_wire_role([term()]) :: :user | :assistant | nil
  def last_wire_role(messages) do
    messages
    |> Enum.reject(fn {role, _} -> role in [:system, :compaction] end)
    |> List.last()
    |> case do
      {:user, _} -> :user
      {:tool, _} -> :user
      {:assistant, _} -> :assistant
      nil -> nil
    end
  end
end
