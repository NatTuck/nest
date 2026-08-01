defmodule Nest.Agents.Agent.Broadcasts.Usage do
  @moduledoc """
  Usage totals helpers extracted from `Nest.Agents.Agent.Broadcasts`
  so that module stays under the credo 500-line cap.

  Owns the `empty_usage_totals/0`, `merge_usage_totals/2`, and
  `total_usage/2` helpers used by the chat:status broadcast
  payload builder. The shape is documented on
  `Broadcasts.empty_usage_totals/0` (the public re-export).
  """

  alias Nest.Tokens.ConversationSize

  @doc """
  Combine two cumulative usage maps. The accumulation logic and
  field shape documentation live on `merge_usage_totals/2`
  below; this short-circuits when both sides are `nil` and
  falls back to `empty_usage_totals/0` for a single `nil`.

  The `totalUsage` field of `status_payload/1` is computed
  here so the JS side never has to add the two halves itself
  (drift-free).
  """
  def total_usage(nil, nil), do: empty_usage_totals()
  def total_usage(direct, nil), do: direct || empty_usage_totals()
  def total_usage(nil, descendant), do: descendant || empty_usage_totals()

  def total_usage(direct, descendant) when is_map(direct) and is_map(descendant) do
    Map.merge(direct || %{}, descendant || %{}, fn _key, a, b -> sum_fields(a, b) end)
  end

  # Field-by-field sum. Both sides are expected to be maps with
  # the canonical shape (`empty_usage_totals/0`); we fall back
  # to 0 for missing or non-integer values so a stale schema on
  # either side can't poison the total.
  defp sum_fields(a, b) when is_integer(a) and is_integer(b), do: a + b
  defp sum_fields(a, _b) when is_integer(a), do: a
  defp sum_fields(_a, b) when is_integer(b), do: b
  defp sum_fields(_, _), do: 0

  @doc """
  Initial / reset state for `usage_totals`. Distinct from the
  `nil` value the accumulator produces: the agent always has a
  map, even before the first LLM call has returned.

  The map carries two axes of state:

    * **Per-call (overwrite)** — the most recent LLM call's
      values, suitable for "what does the context look like
      right now" displays. These are `input_tokens`,
      `cache_read_input_tokens`, `cache_creation_input_tokens`,
      `last_output`, and the derived `context_input_tokens`.

    * **Session (sum)** — cumulative values across every call
      the agent has made, suitable for cost estimation and
      usage dashboards. These are `output_tokens`,
      `total_input_tokens`, `total_cache_read_input_tokens`,
      `total_cache_creation_input_tokens`, `total_tokens`, and
      `reasoning_tokens`.
  """
  def empty_usage_totals do
    %{
      # Per-call (overwrite)
      input_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      context_input_tokens: 0,
      last_output: 0,
      # Session (sum)
      output_tokens: 0,
      total_input_tokens: 0,
      total_cache_read_input_tokens: 0,
      total_cache_creation_input_tokens: 0,
      total_tokens: 0,
      reasoning_tokens: 0
    }
  end

  @doc """
  Combine a fresh usage payload into the running totals.

  The canonical usage map emitted by both clients uses
  `:input_tokens` (new / non-cached input for the most recent
  call), `:cache_read_input_tokens` (served from cache),
  `:cache_creation_input_tokens` (newly written to cache;
  Anthropic only), `:output_tokens` (billed output, reasoning
  included as a subset), and `:reasoning_tokens` (the
  reasoning subset of output).

  - `input_tokens`, `cache_read_input_tokens`,
    `cache_creation_input_tokens` overwrite (most recent call
    is the current state). `context_input_tokens` is derived
    as the sum of those three — the real size of the context
    window for the most recent call.
  - `last_output` mirrors the same overwrite semantics for the
    assistant turn that just finished.
  - `total_input_tokens`, `total_cache_read_input_tokens`,
    `total_cache_creation_input_tokens`, `output_tokens`,
    `total_tokens`, `reasoning_tokens` are summed across the
    session. The cost module reads the `total_*` session
    fields, not the per-call fields, so it can estimate the
    cumulative spend.
  - A `nil` `usage` is a no-op (callers that don't populate it
    shouldn't zero out the running totals).
  """
  def merge_usage_totals(current, nil), do: current

  def merge_usage_totals(current, usage) when is_map(usage) do
    new_call? = Map.has_key?(usage, :input_tokens)

    current
    |> apply_per_call_fields(usage, new_call?)
    |> apply_session_fields(usage)
  end

  # Per-call (overwrite) fields. When this usage payload
  # represents a new LLM call (carries `input_tokens`), pull
  # the per-call value from the payload; otherwise preserve the
  # current value. Cache fields default to 0 when the payload
  # omits them (newer providers may report them; older ones
  # don't).
  defp apply_per_call_fields(current, usage, new_call?) do
    Map.merge(current, %{
      input_tokens: per_call_value(usage, :input_tokens, current, new_call?),
      cache_read_input_tokens:
        per_call_value(usage, :cache_read_input_tokens, current, new_call?),
      cache_creation_input_tokens:
        per_call_value(usage, :cache_creation_input_tokens, current, new_call?),
      last_output: per_call_value(usage, :output_tokens, current, new_call?)
    })
  end

  # Session (sum) fields. Each `total_*` field is the running
  # sum of the per-call value across every LLM call. The
  # `per_call_or_zero` helper returns the per-call value when
  # this payload represents a new call, and 0 otherwise, so
  # session totals are preserved on usage-only updates.
  defp apply_session_fields(current, usage) do
    Map.merge(current, %{
      output_tokens: current.output_tokens + per_call_or_zero(usage, :output_tokens),
      total_input_tokens: current.total_input_tokens + per_call_or_zero(usage, :input_tokens),
      total_cache_read_input_tokens:
        current.total_cache_read_input_tokens +
          per_call_or_zero(usage, :cache_read_input_tokens),
      total_cache_creation_input_tokens:
        current.total_cache_creation_input_tokens +
          per_call_or_zero(usage, :cache_creation_input_tokens),
      total_tokens: current.total_tokens + per_call_or_zero(usage, :total_tokens),
      reasoning_tokens: current.reasoning_tokens + per_call_or_zero(usage, :reasoning_tokens)
    })
  end

  # For "per-call (overwrite)" fields: when this usage payload
  # represents a new LLM call, use the new value. Otherwise
  # keep the prior value.
  defp per_call_value(usage, key, _current, true),
    do: Map.get(usage, key, 0)

  defp per_call_value(_usage, key, current, false),
    do: Map.get(current, key)

  # For "session (sum)" fields: when the payload represents a
  # new LLM call, add the per-call value to the running total.
  # When it doesn't (e.g. a usage update with only output
  # tokens), add 0 so the running total is preserved.
  defp per_call_or_zero(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, v} when is_integer(v) -> v
      _ -> 0
    end
  end

  # Convenience re-export for `Broadcasts.status_payload/1`'s
  # `context_input_tokens` field, which depends on the message
  # list. Lives here so the helper is visible alongside the
  # field shape it derives.
  def context_input_tokens_for(messages) do
    ConversationSize.size(messages)
  end
end
