defmodule Nest.Agents.Agent.CapCalculator do
  @moduledoc """
  Pure functions for the per-batch tool-result cap.

  The BatchSizer owns the cap on inline tool results. This module
  is the math behind it: given the current context state and an
  optional LLM override, return the effective cap (in tokens) or
  `nil` to mean "no cap."

  ## Formula

      usable       = context_limit - estimate_messages(messages) - @preflight_reserve
      default_cap  = floor(usable * 0.80)
      effective    = min(LLM_override, default_cap)   # LLM may only lower

  When `context_limit` is `nil`, no cap is enforced
  (degraded-but-hopeful path).

  See `notes/no-truncation-or-overflow.md` for the design.
  """

  alias Nest.Messages.ToolCall
  alias Nest.Tokens.ConversationSize

  @preflight_reserve 8_192

  # Inline-vs-summary threshold: 80% of the remaining usable
  # context window (computed once per batch; LLM may lower this
  # per call via `max_result_tokens`, never raise it past 80%).
  @inline_share 0.80

  @doc """
  Remaining usable context window in tokens, after subtracting
  the current message list and the preflight reserve. Returns
  `nil` when `ctx.context_limit` is `nil` (degraded-but-hopeful
  path; no cap enforced).

  Uses `ConversationSize.size/1` for the current message list
  size so real-valued tokens from prior LLM responses are
  honored when available.
  """
  @spec usable_remaining(map()) :: non_neg_integer() | nil
  def usable_remaining(%{context_limit: nil}), do: nil

  def usable_remaining(%{context_limit: limit} = ctx)
      when is_integer(limit) and limit > 0 do
    current = ConversationSize.size(ctx.messages || [])
    remaining = limit - current - @preflight_reserve
    if remaining > 0, do: remaining, else: 0
  end

  def usable_remaining(_), do: nil

  @doc """
  The effective inline-result cap for a single tool call.

  Computed as `floor(usable * 0.80)`. If the LLM passed a
  `max_result_tokens` argument, the cap is clamped to
  `min(override, default)` — the LLM may only lower the cap.
  Negative or non-integer overrides fall back to the default.
  Returns `nil` when `usable` is `nil` (no cap).
  """
  @spec effective_max_result_tokens(ToolCall.t(), pos_integer() | nil) ::
          pos_integer() | nil
  def effective_max_result_tokens(%ToolCall{}, nil), do: nil

  def effective_max_result_tokens(%ToolCall{arguments: args}, usable)
      when is_integer(usable) and usable > 0 do
    default = floor(usable * @inline_share)

    case parse_max_result_tokens(args) do
      nil -> default
      override -> min(override, default)
    end
  end

  def effective_max_result_tokens(%ToolCall{}, _usable), do: nil

  defp parse_max_result_tokens(args) when is_map(args) do
    case Map.get(args, "max_result_tokens") do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp parse_max_result_tokens(_), do: nil
end
