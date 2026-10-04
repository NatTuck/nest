defmodule Nest.Agents.Agent.Machine.Turn do
  @moduledoc """
  Pure decision logic for a chat turn's response handling.

  `classify_response/1` is the branch table `ResponseHandler` uses after an
  LLM response arrives. It is pure so it can be exhaustively tested and so
  the eventual in-process turn driver reuses one decision table.

  This module carries no side effects and no Agent state.
  """

  @type response_decision ::
          :compaction
          | :force_finalize
          | :overflow_tool_calls
          | :normal_tool_calls
          | :empty_assistant
          | :truncated
          | :silent
          | :finalize

  @doc """
  Classify a response into the action the turn must take.

  `opts` keys: `:compactor?`, `:force_finalize`, `:has_tool_calls`,
  `:iteration`, `:max_iterations`, `:empty_assistant?`, `:truncated?`,
  `:silent?`.
  """
  @spec classify_response(map()) :: response_decision()
  def classify_response(opts) do
    # Ordered decision table: the first matching predicate wins.
    [
      # The compactor's own turn has a distinct terminal (compaction_done),
      # so it is classified before any ordinary-turn logic.
      {opts.compactor?, :compaction},
      # force_finalize is the max-iterations second chance: persist and end.
      {opts.force_finalize, :force_finalize},
      # Past the cap the model still asked for tools: answer with synthetic
      # errors and re-ask once with force_finalize.
      {opts.has_tool_calls and opts.iteration > opts.max_iterations, :overflow_tool_calls},
      {opts.has_tool_calls, :normal_tool_calls},
      # A zero-part assistant message is never persisted.
      {opts.empty_assistant?, :empty_assistant},
      # Truncated and silent replies are re-prompted before finalizing.
      {opts.truncated?, :truncated},
      {opts.silent?, :silent}
    ]
    |> Enum.find_value(:finalize, fn {matches?, decision} ->
      if matches?, do: decision
    end)
  end
end
