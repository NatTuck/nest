defmodule Nest.Tokens.PreFlight do
  @moduledoc """
  Pre-flight check: would this LLM call fit in the context window?

  Called just before any LLM call (initial chat, after tool
  results, from the `context-check` tool). Returns one of:

    * `:fits` — the projected total is within the context window
      (with reserve). Proceed.
    * `:needs_compaction` — the projected total would overflow,
      and compaction can help. The caller should compact before
      making the call.
    * `:cannot_compact` — the projected total would overflow,
      but compaction would be a no-op (system prompt alone exceeds
      the limit, or there's nothing in the conversation history
      to summarize). The caller should reject the user's request
      with a clear error.

  `context_limit` is always a positive integer in the agent
  runtime (resolved eagerly at init with a 128k `:default`
  floor). Passing `nil` or a non-positive limit matches no
  clause and raises — a request is never sent with an unknown
  limit, and `context_limit` is never optional.

  ## Math

      projected_total = estimated_messages_size + reserve
      decision = projected_total > context_limit
                  ? (:system_alone_exceeds OR :compaction_no_op
                      ? :cannot_compact
                      : :needs_compaction)
                  : :fits

  The `reserve` is the LLM's response budget. It comes from
  `Nest.Tokens.Reserve.response_budget/1` which encodes
  `max(0.20 × context_limit, 8_192)`. When callers don't pass
  an explicit reserve, `check/3` and `check_messages/3`
  default to a flat 8,192 floor — matches `Reserve` at small
  contexts and degrades gracefully when `context_limit` is
  unknown (callers must pass the limit explicitly for the
  scaled reserve to apply).

  ## Why `:cannot_compact`

  Compaction summarizes the *conversation* (everything between the
  system prompt and the last user message). If that span is empty
  — or if the system prompt alone exceeds the limit — compaction
  cannot reduce the message size. The caller would otherwise
  trigger a compaction that produces either a no-op (`:too_short`)
  or a meaningless LLM call (summarizing the bare system prompt),
  leaving the conversation over budget and locking the agent into
  a tool-refusal loop.
  """

  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  @type decision :: :fits | :needs_compaction | :cannot_compact

  @doc """
  Decide whether a planned LLM call fits in the context.

  ## Parameters

    * `estimated_size` — conservative token count for the
      messages we're about to send (from `Nest.Tokens.Estimator`)
    * `context_limit` — the model's context window in tokens
      (a positive integer; `nil`/non-positive raises)
    * `reserve` — tokens to leave free for the LLM's response
      and any subsequent compaction. Default 8,192 (matches
      `Reserve.response_budget/1` at small contexts; pass an
      explicit `Reserve.response_budget(context_limit)` to use
      the scaled value).

  Returns one of `:fits | :needs_compaction | :cannot_compact`.
  """
  @spec check(non_neg_integer(), pos_integer(), pos_integer()) :: decision()
  def check(estimated_size, context_limit, reserve \\ 8_192)

  def check(estimated_size, context_limit, reserve)
      when is_integer(estimated_size) and estimated_size >= 0 and
             is_integer(context_limit) and context_limit > 0 and
             is_integer(reserve) and reserve >= 0 do
    if estimated_size + reserve <= context_limit do
      :fits
    else
      :needs_compaction
    end
  end

  @doc """
  Convenience: pass a list of messages and the context limit, get
  a decision back. Uses `Nest.Tokens.ConversationSize.size/1`
  internally, which combines real-valued tokens (from prior
  LLM responses) with the estimator for any suffix.

  Returns `:cannot_compact` when the conversation fits the
  `:needs_compaction` shape but compaction would be a no-op
  (system prompt alone exceeds the limit, or the head to
  summarize is empty).
  """
  @spec check_messages([Nest.Messages.Message.t()], pos_integer(), pos_integer()) ::
          decision()
  def check_messages(messages, context_limit, reserve \\ 8_192)
      when is_integer(context_limit) and context_limit > 0 do
    cond do
      fits_with_reserve?(messages, context_limit, reserve) ->
        :fits

      system_alone_exceeds?(messages, context_limit, reserve) ->
        :cannot_compact

      compaction_no_op?(messages) ->
        :cannot_compact

      true ->
        :needs_compaction
    end
  end

  defp fits_with_reserve?(messages, limit, reserve) do
    ConversationSize.size(messages) + reserve <= limit
  end

  # The system prompt alone exceeds (context_limit - reserve).
  # No conversation history is small enough to bring us under;
  # the model is fundamentally too small for this configuration.
  defp system_alone_exceeds?(messages, limit, reserve) do
    case Enum.find(messages, &match?({:system, _}, &1)) do
      nil -> false
      sys_msg -> ConversationSize.size([sys_msg]) + reserve > limit
    end
  end

  # Mirrors `Nest.Tokens.Compactor.split_messages/1`'s `:too_short`
  # cases. If the compactor would return `:too_short` (and thus
  # produce an unchanged input), compaction cannot help — there's
  # nothing in the conversation history to summarize away.
  defp compaction_no_op?(messages) do
    case find_last_user_index(messages) do
      nil -> true
      0 -> true
      user_idx -> Enum.empty?(head_to_summarize(messages, user_idx))
    end
  end

  defp head_to_summarize(messages, user_idx) do
    {head, _} = Enum.split(messages, user_idx)

    case head do
      [] -> []
      [_system | rest] -> rest
      _ -> head
    end
  end

  defp find_last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      if match?({:user, _}, msg), do: idx
    end)
  end

  @doc """
  Choke-point guard: raise unless the given message list has
  "passed" the pre-flight decision — i.e. `check_messages/3`
  returns `:fits` or `:needs_compaction`, NOT `:cannot_compact`.

  Used at the LLM-send and message-append choke points so a
  conversation is never sent to, or added to, in a state where
  compaction is impossible. `context_limit` is always a positive
  integer in the agent runtime (resolved eagerly at init with a
  128k `:default` floor); a non-positive limit matches no
  `check_messages/3` clause and raises.
  """
  @spec ensure_passed!([Nest.Messages.Message.t()], pos_integer()) :: :ok
  def ensure_passed!(messages, context_limit) do
    case check_messages(messages, context_limit, Reserve.response_budget(context_limit)) do
      :cannot_compact ->
        raise ArgumentError,
              "pre-flight decision is :cannot_compact for context_limit=#{context_limit}; " <>
                "refusing to send/store rather than risk an unrecoverable overflow"

      _ ->
        :ok
    end
  end
end
