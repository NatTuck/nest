defmodule Nest.Agents.Agent.ChatTurn.BudgetReminder do
  @moduledoc """
  Builds the late reminder injected by the ChatTurn when the
  iteration is approaching the configured cap
  (`max-tool-iterations`). Fires when there are 2 or fewer
  tool-call rounds left. Returns `nil` when no warning is
  needed (more than 2 rounds remaining, or the cap is past).
  The reminder is appended via the Agent, which stamps the index.

  The wire-shape decision (System vs User-bracket) is delegated
  to `Nest.Agents.Agent.ChatTurn.LateMessage.build/2` so all
  late reminders share one router. See the config docstring at
  `Nest.LLM.ClientConfig.rewrite_late_system_messages`.
  """

  alias Nest.Agents.Agent.ChatTurn.LateMessage
  alias Nest.LLM.ClientConfig

  @doc """
  Build a budget reminder for the given `remaining` iteration
  count and `client_config`, or `nil` when no warning is needed.

  The arity-1 form is kept for tests and any internal callers
  that don't yet have a fully-built `ClientConfig` — it
  delegates to the arity-2 form with a default off-config.
  """
  @spec build(integer(), ClientConfig.t()) ::
          {:system, Nest.Messages.System.t()}
          | {:user, Nest.Messages.User.t()}
          | nil
  def build(remaining, _client_config) when not is_integer(remaining), do: nil

  def build(remaining, _client_config) when remaining > 2 or remaining <= 0, do: nil

  def build(remaining, client_config) do
    warning =
      case remaining do
        2 ->
          "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

        1 ->
          "This is your last tool call round. After this, no more tools will be available — provide your final response."
      end

    LateMessage.build(client_config, warning)
  end

  @spec build(integer()) ::
          {:system, Nest.Messages.System.t()}
          | {:user, Nest.Messages.User.t()}
          | nil
  def build(remaining),
    do:
      build(
        remaining,
        %ClientConfig{rewrite_late_system_messages: false}
      )
end
