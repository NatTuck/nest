defmodule Nest.Tokens.BudgetPlanner do
  @moduledoc """
  Executes a batch of tool calls under a token budget.

  Iterates one call at a time. After each call, one of three things
  happens:

    * **Fits as-is** — the result is smaller than the per-call
      budget. Keep it.
    * **Truncates** — the result is larger than the per-call budget.
      Head-truncate to fit (with a note) — provided the kept chunk
      is at least `min_truncatable_content` tokens.
    * **Skipped** — the result is too large even truncated, or the
      per-call budget is too small to be useful. Return a synthetic
      skip response.

  If a call is skipped, *all* remaining unprocessed calls in the
  batch are also skipped — the budget cascade is terminal. There
  is no point in continuing once the LLM has been told "context is
  exhausted" for this batch.

  ## Per-call budget

  The per-call budget is the *remaining* context budget minus a
  fixed per-call overhead (~200 tokens for the tool message wire
  format) and a forward-looking reservation for the worst case
  (skip responses for all unprocessed calls). See the plan in
  `notes/context-and-compaction.md` for the exact formula.

  ## Executor callback

  The `executor_fn` is called once per tool call and must return
  `{result_string, tool_default_max_result_tokens}`. The tool's
  default `max_result_tokens` is the per-call cap; the LLM can
  override it on a per-call basis by passing
  `max_result_tokens` in the call's arguments (read directly from
  `tool_call.arguments` by this module).
  """

  alias Nest.Messages.ToolCall
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.SkipResponse
  alias Nest.Tokens.Truncate

  @default_base_overhead 200
  @default_skip_size 70
  @default_min_truncatable 256
  @default_note_size 40
  @default_min_skip_trigger 200
  @default_min_useful 100
  @default_max_result_tokens 8192

  @type tool_call :: ToolCall.t() | map()
  @type result :: String.t()
  @type kind :: :ok | :error
  @type executor ::
          (tool_call() ->
             {:ok, result(), pos_integer()} | {:error, result(), pos_integer()})

  @doc """
  Execute a batch of tool calls under `budget_remaining` tokens.

  Returns a list of `{tool_call, result_string}` tuples in the same
  order as the input. Each `result_string` is either the tool's
  full output, a truncated output with a note, or a skip response.

  ## Options

    * `:base_overhead` — per-call fixed overhead (default #{@default_base_overhead})
    * `:skip_response_size` — tokens a skip response consumes
      (default #{@default_skip_size})
    * `:min_truncatable` — minimum kept-tokens for truncation;
      below this we skip instead (default #{@default_min_truncatable})
    * `:note_size` — tokens the truncation note consumes
      (default #{@default_note_size})
    * `:min_skip_trigger` — if `budget_for_this` is below this,
      skip this and all remaining calls (default #{@default_min_skip_trigger})
    * `:min_useful` — minimum useful size; below this the call
      is treated as too small to bother truncating (default #{@default_min_useful})
    * `:default_max_result_tokens` — fallback per-tool cap when
      the executor doesn't return one (default #{@default_max_result_tokens})
  """
  @spec execute([tool_call()], executor(), pos_integer(), keyword()) ::
          [{tool_call(), {kind(), result()}}]
  def execute(tool_calls, executor_fn, budget_remaining, opts \\ [])
      when is_list(tool_calls) and is_function(executor_fn, 1) and
             is_integer(budget_remaining) do
    cfg = build_config(opts)

    do_execute(tool_calls, executor_fn, budget_remaining, cfg)
  end

  defp build_config(opts) do
    %{
      base_overhead: Keyword.get(opts, :base_overhead, @default_base_overhead),
      skip_size: Keyword.get(opts, :skip_response_size, @default_skip_size),
      min_truncatable: Keyword.get(opts, :min_truncatable, @default_min_truncatable),
      note_size: Keyword.get(opts, :note_size, @default_note_size),
      min_skip_trigger: Keyword.get(opts, :min_skip_trigger, @default_min_skip_trigger),
      min_useful: Keyword.get(opts, :min_useful, @default_min_useful),
      default_max: Keyword.get(opts, :default_max_result_tokens, @default_max_result_tokens)
    }
  end

  defp do_execute([], _executor_fn, _remaining, _cfg), do: []

  defp do_execute([call | rest], executor_fn, remaining, cfg) do
    unprocessed = length(rest)
    future_skip_cost = unprocessed * cfg.skip_size
    budget_for_this = remaining - cfg.base_overhead - future_skip_cost

    if budget_for_this >= cfg.min_skip_trigger do
      run_or_skip(call, rest, executor_fn, remaining, budget_for_this, cfg)
    else
      # Not enough room for any useful call — skip this and all
      # remaining. Charge each skip at the configured size.
      Enum.map([call | rest], fn tc ->
        {tc, {:ok, SkipResponse.render(call_name(tc), budget_for_this)}}
      end)
    end
  end

  defp run_or_skip(call, rest, executor_fn, remaining, budget_for_this, cfg) do
    {kind, raw_result, default_max} = executor_fn.(call)
    effective_max = effective_max_result_tokens(call, default_max)
    max_content_budget = min(budget_for_this - cfg.note_size, effective_max)

    cond do
      should_skip?(max_content_budget, cfg) ->
        skip_remaining(call, kind, rest, executor_fn, remaining, budget_for_this, cfg)

      fits?(raw_result, max_content_budget, cfg) ->
        keep_as_is(call, kind, raw_result, rest, executor_fn, remaining, cfg)

      true ->
        truncate(call, kind, raw_result, max_content_budget, rest, executor_fn, remaining, cfg)
    end
  end

  defp should_skip?(max_content_budget, cfg) do
    # Even the max-allowed content wouldn't be useful — skip.
    max_content_budget < cfg.min_truncatable
  end

  defp skip_remaining(call, kind, rest, executor_fn, remaining, budget_for_this, cfg) do
    skip = SkipResponse.render(call_name(call), budget_for_this)

    [
      {call, {kind, skip}}
      | do_execute(
          rest,
          executor_fn,
          max(0, remaining - cfg.skip_size - cfg.base_overhead),
          cfg
        )
    ]
  end

  defp keep_as_is(call, kind, raw_result, rest, executor_fn, remaining, cfg) do
    # Fits within both budget and tool cap; keep as-is.
    [
      {call, {kind, raw_result}}
      | do_execute(rest, executor_fn, remaining - charge(raw_result, cfg), cfg)
    ]
  end

  defp truncate(call, kind, raw_result, max_content_budget, rest, executor_fn, remaining, cfg) do
    # Truncate to the smaller of (budget, tool cap).
    {kept, note} = Truncate.head_with_note(raw_result, max_content_budget, cfg.note_size)

    [
      {call, {kind, kept <> note}}
      | do_execute(rest, executor_fn, remaining - charge(kept, cfg) - cfg.note_size, cfg)
    ]
  end

  # Effective cap = tool's default or the LLM's per-call override.
  # The 50% ceiling on `max_result_tokens` is enforced at the agent's
  # tool-schema layer (the LLM is told the ceiling), so we don't
  # re-clamp here.
  defp effective_max_result_tokens(call, default_max) do
    case call_max_override(call) do
      nil -> default_max
      override when override > 0 -> override
    end
  end

  defp call_max_override(%ToolCall{arguments: args}) when is_map(args) do
    Map.get(args, "max_result_tokens")
  end

  defp call_max_override(%{arguments: args}) when is_map(args) do
    Map.get(args, "max_result_tokens")
  end

  defp call_max_override(_), do: nil

  defp call_name(%ToolCall{name: name}), do: name || "unknown"
  defp call_name(%{name: name}), do: name || "unknown"
  defp call_name(_), do: "unknown"

  # Use the conservative `estimate/1` (which applies the 20% safety
  # margin) for the actual fit check. The raw string would otherwise
  # under-count the wire-format overhead the LLM will see.
  defp fits?(result, budget, cfg) do
    budget - Estimator.estimate(result) >= cfg.min_useful
  end

  # What we charge against the budget for a kept result: its
  # conservative size plus the per-call overhead. This is the same
  # accounting the pre-flight check uses, so the budget is
  # consistent end-to-end.
  defp charge(string, cfg) do
    Estimator.estimate(string) + cfg.base_overhead
  end
end
