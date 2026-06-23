defmodule Nest.Tokens.PreFlight do
  @moduledoc """
  Pre-flight check: would this LLM call fit in the context window?

  Called just before any LLM call (initial chat, after tool
  results, from the `context` tool). Returns one of:

    * `:fits` — the projected total is within the context window
      (with reserve). Proceed.
    * `:needs_compaction` — the projected total would overflow.
      The caller should compact before making the call.
    * `:no_limit_known` — we don't have a context limit for this
      model (no config, no probe). Skip the check; proceed
      optimistically.

  ## Math

      projected_total = estimated_messages_size + reserve
      decision = projected_total > context_limit
                  ? :needs_compaction
                  : :fits

  The reserve is the budget we want to leave for the LLM's
  response and any subsequent compaction. Defaults to 8,192
  tokens.
  """

  alias Nest.Tokens.Estimator

  @default_reserve 8_192

  @type decision :: :fits | :needs_compaction | :no_limit_known

  @doc """
  Decide whether a planned LLM call fits in the context.

  ## Parameters

    * `estimated_size` — conservative token count for the
      messages we're about to send (from `Nest.Tokens.Estimator`)
    * `context_limit` — the model's context window in tokens, or
      `nil` if unknown
    * `reserve` — tokens to leave free for the LLM's response
      and any subsequent compaction (default #{@default_reserve})

  Returns one of `:fits | :needs_compaction | :no_limit_known`.
  """
  @spec check(non_neg_integer(), pos_integer() | nil, pos_integer()) :: decision()
  def check(estimated_size, context_limit, reserve \\ @default_reserve)

  def check(_estimated_size, nil, _reserve), do: :no_limit_known

  def check(estimated_size, context_limit, reserve)
      when is_integer(estimated_size) and estimated_size >= 0 and
             is_integer(context_limit) and context_limit > 0 and
             is_integer(reserve) and reserve >= 0 do
    if estimated_size + reserve > context_limit do
      :needs_compaction
    else
      :fits
    end
  end

  @doc """
  Convenience: pass a list of messages and the context limit, get
  a decision back. Wraps `Nest.Tokens.Estimator.estimate_messages/1`.
  """
  @spec check_messages([Nest.Messages.Message.t()], pos_integer() | nil, pos_integer()) ::
          decision()
  def check_messages(messages, context_limit, reserve \\ @default_reserve) do
    check(Estimator.estimate_messages(messages), context_limit, reserve)
  end
end
