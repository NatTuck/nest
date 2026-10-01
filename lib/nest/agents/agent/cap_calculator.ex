defmodule Nest.Agents.Agent.CapCalculator do
  @moduledoc """
  Pure functions for the per-batch tool-result cap.

  The BatchSizer owns the cap on inline tool results. This module
  is the math behind it: given the current context state and an
  optional LLM override, return the effective cap (in tokens).

  ## Formula

      reserve       = Nest.Tokens.Reserve.compaction_reserve(context_limit)
      usable        = context_limit - estimate_messages(messages) - reserve
      default_cap   = floor(usable * 0.80)
      effective     = min(LLM_override, default_cap)   # LLM may only lower

  When `context_limit` is `nil` (or non-positive), the clauses below
  match nothing and raise — the limit is never optional, so there is
  no "no cap" state.

  See `notes/no-truncation-or-overflow.md` for the design.
  """

  alias Nest.Messages.ToolCall
  alias Nest.Tokens.Budget

  # Inline-vs-summary threshold: 80% of the remaining usable
  # context window (computed once per batch; LLM may lower this
  # per call via `max_result_tokens`, never raise it past 80%).
  @inline_share 0.80

  @doc """
  Remaining usable content budget in tokens: `L - C - size(messages)`
  (the compaction reserve `C` is never available to tool results).

  Delegates to `Nest.Tokens.Budget.remaining/2`, which uses
  `ConversationSize.size/1` so real-valued tokens from prior LLM
  responses are honored when available. Requires a positive
  `ctx.context_limit` — a nil/non-positive value raises.
  """
  @spec usable_remaining(map()) :: non_neg_integer()
  def usable_remaining(%{context_limit: limit} = ctx)
      when is_integer(limit) and limit > 0 do
    Budget.remaining(ctx.messages || [], limit)
  end

  @doc """
  The effective inline-result cap for a single tool call.

  Computed as `floor(usable * 0.80)`. If the LLM passed a
  `max_result_tokens` argument, the cap is clamped to
  `min(override, default)` — the LLM may only lower the cap.
  Negative or non-integer overrides fall back to the default.
  Requires a positive `usable` — a nil/zero value raises.
  """
  @spec effective_max_result_tokens(ToolCall.t(), pos_integer()) :: pos_integer()
  def effective_max_result_tokens(%ToolCall{arguments: args}, usable)
      when is_integer(usable) and usable > 0 do
    default = floor(usable * @inline_share)

    case parse_max_result_tokens(args) do
      nil -> default
      override -> min(override, default)
    end
  end

  defp parse_max_result_tokens(args) when is_map(args) do
    case Map.get(args, "max_result_tokens") do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp parse_max_result_tokens(_), do: nil
end
