defmodule Nest.Agents.Agent.ChatTurn.BudgetReminder do
  @moduledoc """
  Builds the budget-remaining notice injected by the ChatTurn
  when the iteration is approaching the configured cap
  (`max-tool-iterations`). Fires when there are 2 or fewer
  tool-call rounds left. Returns nil when no warning is needed.

  The notice text is deferred and attaches to the next tool
  response as a `Part.Text`. Since budget reminders only fire
  during active tool sequences, there is always a tool response
  to attach to.
  """

  @doc """
  Returns the notice text for the given `remaining` iteration
  count, or `nil` when no warning is needed.
  """
  @spec notice_text(integer()) :: String.t() | nil
  def notice_text(remaining) when not is_integer(remaining), do: nil
  def notice_text(remaining) when remaining > 2 or remaining <= 0, do: nil

  def notice_text(2),
    do: "2 tool call rounds remaining. Plan your remaining tool use carefully."

  def notice_text(1),
    do: "Last tool call round. Provide your final response after this tool."
end
