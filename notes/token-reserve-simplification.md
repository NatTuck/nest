# Token reserve simplification

A single source of truth for the agent's LLM response budget.

## What changed

Three independent knobs — the chat call's response reserve, the
compactor's 5% safety margin, and the 25% recent-slice ceiling —
collapse into one number: `Nest.Tokens.Reserve.response_budget/1`.

| Before | After |
|---|---|
| `ChatPipeline.@preflight_reserve 8_192` | `Reserve.response_budget(context_limit)` |
| `BatchSizer.@preflight_reserve 8_192` | `Reserve.response_budget(context_limit)` |
| `CapCalculator.@preflight_reserve 8_192` | `Reserve.response_budget(context_limit)` |
| `ToolLoop.@budget_reserve 8_192` | `Reserve.response_budget(context_limit)` |
| `PreFlight.@default_reserve 8_192` | `Reserve.response_budget(context_limit)` |
| `Compactor.@recent_threshold 0.25` (refuse gate) | dropped (no recent slice preserved) |
| `Compactor.estimate_remaining_tokens/2` 5% safety | replaced by `compute_summary_budget/4` |
| `Compactor.estimate_remaining_tokens/2` recent-slice hint | replaced by `compute_summary_budget/4` |

The reserve formula:

```
reserve = max(0.20 × context_limit, 8_192)
```

At small contexts (≤ 40k), the floor wins. Above that, the share
scales with the model's context window.

## Why

The same 8,192 token number lived in five different constants
under three different names: `@preflight_reserve`,
`@budget_reserve`, `@default_reserve`. Drift between them was a
real risk — touching one and not the others would have silently
broken budget arithmetic across the system. Centralizing removes
that risk: a single edit at `Reserve.@response_floor` /
`Reserve.@response_share` propagates everywhere.

The 5% safety (compactor's `max(1_000, 5% × limit)`) was a
defensive heuristic that conflated two distinct concerns: the
LLM's response headroom and provider/cache drift. Under the new
design, the LLM's response headroom is `reserve` itself, and the
drift absorption is handled by the existing 1.20× estimator
multiplier applied per call. The 5% safety no longer has a job.

The 25% recent-slice ceiling (`@recent_threshold`) becomes the
post-compaction size target rather than a refusal gate. With
recent-slice preservation gone (see below), the compactor
produces `[system, summary]` on the `{:ok, _}` branch with no
refusal — `:reserve_exhausted` (system + request overflow the
LLM's response budget) is the only refusal path.

## Recent-slice preservation is gone

The previous design kept `[system, head_summary, last_user,
responses]` verbatim after compaction. The new design produces
`[system, summary]`: the entire conversation folds into a single
LLM-produced summary.

At small contexts (32k), a single `execute_command` result can
consume half the window on its own. Preserving the recent slice
alongside the head summary routinely blew past 25% of context in
the post-compaction state. Dropping recent-slice preservation
sidesteps the issue: the LLM's summary captures the local tool
flow as part of the fold.

The post-compaction target is now an aspirational goal, not a
hard cap. `p25` in `Nest.Agents.Agent.ChatTurn.ContextReminder`
continues to fire as a reminder when usage crosses 25%, but it
no longer shapes the compactor's sizing.

## How `<N>` is computed

`Nest.Tokens.Compactor.compute_summary_budget/4` returns
`{:ok, n, rendered_suffix}` where:

```
reserve       = Reserve.response_budget(context_limit)
system_size   = Estimator.estimate_message(system_msg)
suffix_base   = Estimator.estimate_message(render_suffix(N=1, guidance))
suffix_size   = suffix_base + @digit_count_buffer  (10)

n_headroom    = max(0, reserve - system_size - suffix_size)
n_call_fits   = max(0, context_limit - Estimator.estimate_messages(current_messages) - suffix_size)
n             = min(n_headroom, n_call_fits) clamped to ≥ 0

rendered_suffix = render_suffix(n, guidance)  # rendered with the chosen N
```

Single-pass — no recursive render. The `@digit_count_buffer` of
10 tokens absorbs the variance between `N=1` (1 char) and the
actual N (up to 6 chars for billion-token contexts). Worst-case
delta is ~2 tokens; 10 is conservative.

On `n = 0`, returns `{:error, :reserve_exhausted}`. The agent's
compaction handler surfaces this as `:context_overflow` so the
user sees "system prompt + compaction request consume the LLM's
full response budget — use a smaller system prompt or change
model" rather than a silent no-op.

## What gets passed where

The handler computes `compute_summary_budget/4` once at spawn
time. The `rendered_suffix` is passed through to
`Nest.Agents.Agent.Compaction.spawn/6` (added in this PR), which
forwards it to `build_summarization_llm_call/2`. The LLM call
appends the rendered suffix directly — no re-render, no
re-measurement at call time, so the suffix size the budget was
sized against matches the suffix on the wire.

The `remaining_tokens` and `optional_guidance` fields are still
embedded in the rendered suffix for downstream observability but
the compactor's spawn API no longer accepts them as separate
arguments. The `compute_summary_budget/4` function is the single
place they enter the system.

## Migration table

| Old | New |
|---|---|
| `Compactor.estimate_remaining_tokens/2` | `Compactor.compute_summary_budget/4` |
| `Compactor.compact/3` returning `{:error, :recent_slice_too_large}` | (refusal removed; only `{:error, :llm_returned_empty}` remains) |
| `Compactor.@recent_threshold 0.25` | dropped |
| `Compaction.spawn/7` taking `remaining_tokens`, `optional_guidance` | `Compaction.spawn/6` taking `rendered_suffix` |
| `CompactionProbeSupport.build_summarization_llm_call/4` | `build_summarization_llm_call/3` taking `rendered_suffix` |
| Five duplicate reserve constants | `Reserve.response_budget/1` |
| `:recent_slice_too_large` failure reason | dropped |

## Knobs remaining after this PR

- `0.20` — reserve share.
- `0.25` / `0.50` / `0.75` — `ContextReminder` thresholds (informational; `p25` no longer load-bearing for compaction).
- `0.80` — `CapCalculator.@inline_share` (per-tool result cap).
- `1.20` × 2 — `Estimator.@safety_multiplier`, `BatchSizer.@safety_padding`.
- `10` × 2 — `Estimator.@per_message_overhead`, `Compactor.@digit_count_buffer`.
- `8_192` — `Reserve.@response_floor`; `Tools.@default_max_result_tokens`.
