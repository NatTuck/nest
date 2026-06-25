defmodule Nest.Agents.Agent.ChatTurn.BudgetReminder do
  @moduledoc """
  Builds the late `{:system, _}` reminder injected by the
  ChatTurn when the iteration is approaching the configured
  cap (`max-tool-iterations`).

  Fires when there are 2 or fewer tool-call rounds left.
  Returns `nil` when there's no need to warn (more than 2
  rounds remaining, or the cap is already past). The reminder
  is appended via the Agent, which stamps the index.
  """

  @doc """
  Build a budget reminder for the given `remaining` iteration
  count, or `nil` when no warning is needed.
  """
  @spec build(integer()) :: {:system, Nest.Messages.System.t()} | nil
  def build(remaining) when remaining > 2 or remaining <= 0, do: nil

  def build(remaining) do
    warning =
      case remaining do
        2 ->
          "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

        1 ->
          "This is your last tool call round. After this, no more tools will be available — provide your final response."
      end

    {:system, %Nest.Messages.System{content: warning, timestamp: DateTime.utc_now()}}
  end
end
