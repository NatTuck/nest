defmodule Nest.Tokens.Reserve do
  @moduledoc """
  The **compaction reserve**: the headroom we always keep free so a
  conversation can always be compacted.

  ## The core goal: we can always compact

  If the context ever fills up with no room left to run a *single-pass*
  compaction (a summarization request + the model's thinking + the summary
  response), the only recovery is the multi-stage, uncached, slow, expensive
  offline path. We never want that during normal operation. So we reserve the
  space a compaction needs and never spend it on anything else.

      C = compaction_reserve(L) = max(0.20 x L, 8_192)

  The invariant is enforced everywhere context is sized:

      for the live LLM-facing context M:   size(M) + C  <=  L

  Ordinary content — the system message, the summary, user messages, tool
  results, synthetic notices/nudges, and **ordinary model replies** — lives
  entirely in `L - C`. The only operation allowed to spend `C` is a
  compaction (its request and its response). A proposed ordinary message that
  would cross `L - C` is deferred and compaction runs first. Because
  `size(M) + C <= L` always holds, `M` plus a small `[mode: compact]` suffix
  always fits under `L`, and `C` always funds the summary response.

  `compaction_reserve/1` is the single source of this number. It backs the
  send preflight (`Nest.Tokens.PreFlight`), the per-tool result cap
  (`Nest.Agents.Agent.CapCalculator.usable_remaining/1`), the content-budget
  display (`Broadcasts.Usage` / `TokenUsageChip`), the compactor's `<N>` hint
  (`Nest.Tokens.Compactor.compute_summary_budget/4`), and the context-overflow
  message (`Nest.Agents.Agent.Compaction.Overflow`). It is **not** the model's
  reply budget — replies are deferred past the reserve, never funded from it.

  See `notes/compaction-reserve-plan.md` for the full design.

  ## Formula

      C = max(0.20 x context_limit, 8_192)

  At small contexts (<= 40k tokens) the flat 8,192 floor wins; above that the
  20% share scales with the model window so larger-context models get
  proportionally larger compaction headroom.

  ## Why the floor is part of the formula

  The 8,192 floor is a deliberate minimum: even tiny contexts need enough room
  for a summarization request plus a sensible summary. Before this module
  existed the same 8,192 lived in five constants under three names
  (`@preflight_reserve`, `@budget_reserve`, `@default_reserve`) in five files;
  centralizing means a single edit at `@compaction_share` / `@compaction_floor`
  propagates to every call site.
  """

  @compaction_share 0.20
  @compaction_floor 8_192

  @type t :: pos_integer()

  @doc """
  The compaction reserve for `context_limit`, in tokens.

  Returns `max(0.20 x context_limit, 8_192)`. Keep the live context at or
  below `context_limit - C`; spend `C` only on a compaction.

  Raises `FunctionClauseError` for non-positive `context_limit`.
  `context_limit` is always a positive integer in the agent runtime (resolved
  eagerly at init with a 128k `:default` floor), so the degenerate `nil` case
  does not exist.
  """
  @spec compaction_reserve(pos_integer()) :: t()
  def compaction_reserve(context_limit)
      when is_integer(context_limit) and context_limit > 0 do
    max(@compaction_floor, round(context_limit * @compaction_share))
  end
end
