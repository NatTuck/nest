defmodule Nest.Tokens.Budget do
  @moduledoc """
  The single accounting predicate for the compaction-reserve invariant.

  ## Core goal: we can always compact

  A live conversation must always leave enough room to run a single-pass
  compaction. `Reserve.compaction_reserve/1` is that headroom (`C`), and it is
  never spent on ordinary content. The invariant is:

      for the live LLM-facing context M:   size(M) + C  <=  L

  where `size/1` is `ConversationSize` (the real token floor the provider
  reported for the last message it saw, plus an estimate for the unseen
  suffix) and `L` is the model's context limit.

  This module is the one place that predicate lives. Every go/no-go decision
  (send, append, tool-result cap, compactor budget) should call `fits?/2` or
  `remaining/2` so the whole system shares one basis. `Nest.Tokens.Estimator`
  is used only to *project* content that does not exist yet (future tool
  outputs, the in-flight reply); it must not be used to size the live context.

  See `notes/compaction-reserve-plan.md`.
  """

  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  @doc "The size of a live message list, in tokens (`ConversationSize`)."
  @spec size([term()]) :: non_neg_integer()
  def size(messages), do: ConversationSize.size(messages)

  @doc """
  The content budget for `context_limit`: `L - C`. Ordinary content (including
  ordinary replies) must fit here; `C` is reserved for compaction.
  """
  @spec content_limit(pos_integer()) :: non_neg_integer()
  def content_limit(context_limit) when is_integer(context_limit) and context_limit > 0 do
    max(0, context_limit - Reserve.compaction_reserve(context_limit))
  end

  @doc """
  True when `messages` leave the compaction reserve intact:
  `size(messages) + C <= L`.
  """
  @spec fits?([term()], pos_integer()) :: boolean()
  def fits?(messages, context_limit) when is_integer(context_limit) and context_limit > 0 do
    size(messages) + Reserve.compaction_reserve(context_limit) <= context_limit
  end

  @doc "Tokens of content budget remaining: `L - C - size(messages)`, floored at 0."
  @spec remaining([term()], pos_integer()) :: non_neg_integer()
  def remaining(messages, context_limit)
      when is_integer(context_limit) and context_limit > 0 do
    max(0, content_limit(context_limit) - size(messages))
  end
end
