defmodule Nest.Tokens.Cost do
  @moduledoc """
  Cost estimation for an LLM session, in USD.

  The estimate is a sum of three components, each priced per
  million tokens:

    * **Input** — `total_input_tokens` of the session (new,
      non-cached). Billed at the standard input rate.
    * **Cached input** — `total_cache_read_input_tokens` of the
      session (Anthropic cache reads, OpenAI `cached_tokens`).
      Billed at the discounted cache rate.
    * **Output** — `output_tokens` of the session. This already
      includes `reasoning_tokens` (Anthropic extended thinking,
      OpenAI o1-style reasoning, etc.) — the per-call
      `completion_tokens` field on OpenAI and the per-call
      `output_tokens` field on Anthropic both count reasoning
      output. The cost module treats the whole `output_tokens`
      number as billable, so reasoning is never silently dropped
      from the total.

  `cache_creation_input_tokens` is captured by the streaming
  clients and visible in the API logs, but it is **not** added
  separately to the cost: Anthropic reports it as a subset of
  `input_tokens` (the new tokens that are being written to
  cache), so the standard input rate already covers it. The
  user's directive — "treat cache_creation the same as input"
  — falls out of the data shape.

  The rates are hardcoded constants for now. The shape of this
  module (one entry point, one return) is the seam for a future
  move to per-model config (DotConfig or a `model_pricing`
  table); the call site in the UI only needs the resulting
  number.
  """

  alias Decimal, as: D

  # Rates in USD per 1,000,000 tokens.
  @input_rate D.new("1.00")
  @cached_input_rate D.new("0.25")
  @output_rate D.new("4.00")

  @one_million D.new(1_000_000)

  @doc """
  Estimate the cumulative session cost in USD.

  Accepts the `usage_totals` map produced by
  `Nest.Agents.Agent.Broadcasts.merge_usage_totals/2`. Missing
  fields default to 0 so the function is safe to call against
  older wire payloads (e.g. a server in the middle of being
  rolled out) and against tests that don't populate every key.

  Returns a `Decimal.t()` so the caller can format to any
  precision without float artifacts. The UI helper
  `assets/js/utils/cost.js` mirrors this formula on the
  client side for display.
  """
  @spec estimate(map()) :: D.t()
  def estimate(usage_totals) when is_map(usage_totals) do
    input = D.new(Map.get(usage_totals, :total_input_tokens, 0) || 0)
    cached = D.new(Map.get(usage_totals, :total_cache_read_input_tokens, 0) || 0)
    output = D.new(Map.get(usage_totals, :output_tokens, 0) || 0)

    input
    |> D.mult(@input_rate)
    |> D.add(D.mult(cached, @cached_input_rate))
    |> D.add(D.mult(output, @output_rate))
    |> D.div(@one_million)
  end

  def estimate(_), do: D.new(0)
end
