defmodule Nest.Tokens.Reserve do
  @moduledoc """
  Single source of truth for the agent's LLM response budget.

  Every reserve / budget-headroom constant in the agent's
  context math comes from `response_budget/1`. One number drives
  the chat call's preflight (via `Nest.Tokens.PreFlight.check/3`
  and `check_messages/3`), the per-tool result cap (via
  `Nest.Agents.Agent.CapCalculator.usable_remaining/1`), the
  working-space display (via `Nest.Agents.Agent.ToolLoop`'s
  `estimate_new_working_space/2`), the compactor's `<N>` budget
  hint (via `Nest.Tokens.Compactor.compute_summary_budget/4`),
  and the context-overflow error message (via
  `Nest.Agents.Agent.ChatPipeline.overflow_message/1`).

  ## Formula

      reserve = max(0.20 × context_limit, 8_192)

  At small contexts (≤ 40k tokens), the flat 8,192-token floor
  wins. Above that, the 20% share scales with the model's
  context window so larger-context models get proportionally
  larger response budgets.

  ## Why share × limit

  The reserve is the LLM's response headroom on any single
  call. The actual response length is independent of input size
  (the LLM responds the same to a 5k-input or 50k-input
  request), so a flat number is closer to reality than a
  context-scaled one. But on large-context models the LLM's
  response often grows with the conversation (longer tool
  flows warrant longer answers), so a 20% ceiling matches
  observed usage.

  The 8,192 floor is a deliberate minimum: even tiny contexts
  need a sensible response budget — Anthropic recommends
  ~8k for Sonnet and most open-weight providers are similar.

  ## Why the floor is part of the formula

  Before this module existed, the same 8,192 lived in five
  different constants under three different names
  (`@preflight_reserve`, `@budget_reserve`, `@default_reserve`)
  in five different files. Drift was a real risk — touching
  one and not the others would silently break budget
  arithmetic. Centralizing here means a single edit at the
  @response_floor / @response_share attributes propagates to
  every call site.
  """

  @response_share 0.20
  @response_floor 8_192

  @type t :: pos_integer()

  @doc """
  The LLM's response budget for `context_limit`, in tokens.

  Returns `max(0.20 × context_limit, 8_192)`. Used by all six
  call sites that need this number (see moduledoc).

  Raises `FunctionClauseError` for non-positive `context_limit`.
  `context_limit` is always a positive integer in the agent
  runtime (resolved eagerly at init with a 128k `:default`
  floor), so the degenerate `nil` case no longer exists.
  """
  @spec response_budget(pos_integer()) :: t()
  def response_budget(context_limit)
      when is_integer(context_limit) and context_limit > 0 do
    max(@response_floor, round(context_limit * @response_share))
  end
end
