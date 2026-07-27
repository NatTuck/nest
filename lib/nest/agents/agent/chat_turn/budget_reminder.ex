defmodule Nest.Agents.Agent.ChatTurn.BudgetReminder do
  @moduledoc """
  Builds the budget-remaining notice injected by the ChatTurn
  when the iteration is approaching the configured cap
  (`max-tool-iterations`). Fires when there are 2 or fewer
  tool-call rounds left. Returns nil when no warning is needed.

  The notice is injected at the LLM-response-construction site
  (Case 2) as a synthetic `[assistant("Tool limit?"),
  user(notice)]` pair before the LLM's next response. The
  attention text "Tool limit?" is type-specific — it
  distinguishes this notice from context-usage threshold
  notices (which use "Context?") and any future notice types.

  Notice specs (the generic mechanism for Case 2 injection):

  `spec/1` returns a `%{kind, attention, notice}` map when the
  budget fires, or `nil` otherwise. See
  `ContextReminder.spec/3` for the parallel context-usage
  mechanism and `ResponseHandler.collect_case2_specs/2` for
  how specs are collected and injected.
  """

  @type spec :: %{kind: atom(), attention: String.t(), notice: String.t()}

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

  @doc """
  Build a complete notice spec for the budget reminder. Returns
  the spec map (attention + notice) when the budget fires, or
  `nil` when no warning is needed. The attention text
  "Tool limit?" signals to the LLM that the next user message
  is a tool-call budget reminder, distinguishing it from
  other notice types (e.g. context-usage thresholds).
  """
  @spec spec(integer()) :: spec() | nil
  def spec(remaining) do
    case notice_text(remaining) do
      nil -> nil
      notice -> %{kind: :budget, attention: "Tool limit?", notice: notice}
    end
  end

  @doc """
  Build a spec from a pre-computed notice text. Used by the
  ResponseHandler when the budget reminder notice has already
  been computed (in `state.pending_notice`) and only needs to
  be wrapped in the spec envelope.
  """
  @spec spec_from_pending(String.t()) :: spec()
  def spec_from_pending(notice) do
    %{kind: :budget, attention: "Tool limit?", notice: notice}
  end
end
