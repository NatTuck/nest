# `max_result_tokens` design — no truncation, no overflow

## Goal

Wire up `max_result_tokens` (declared in every tool's JSON schema today
but never read at runtime) as a real cap on tool result size. Two
non-negotiable rules:

1. **No truncations** — the LLM never sees a partially-degraded tool
   result. Either the full content or a summary pointing to a file.
2. **No overflows** — the BatchSizer's preflight guarantees space for the
   minimum size of every tool call in the batch *before* any tool runs.
   The BatchSizer knows there's enough room.

The cap is computed as **80% of the remaining usable context window**,
computed once at the start of each batch. The LLM can lower it (ask for a
tighter cap → forces the summary path even when full content fits inline)
but cannot raise it.

## Why "no truncation"

The legacy `BudgetPlanner` truncated tool output heuristically when it
overflowed the budget. That was lossy: the LLM saw a degraded version of
the file/command output with no pointer to the full version. The
BatchSizer replaces this with a binary choice per tool result:

- **Full content** ships to the LLM inline, OR
- **Path-and-head summary** ships to the LLM inline, with the full
  content written to a temp file the LLM can re-read.

There is no third option ("truncate a little inline"). The user
explicitly confirmed this is the desired shape.

## Why "no overflow"

The BatchSizer preflight already projects each tool's **minimum size**
(the size it would take if summarized to a path-and-head block) and
refuses the batch when `messages + sum(minimum_sizes) + reserve > limit`.
The existing preflight uses `summary_baseline_size() * @safety_padding`
for `execute_command` (see `lib/nest/agents/agent/batch_sizer.ex:113-115`)
— that 20% padding is the "minimum space we know we'll need even in the
worst case" reserve.

The cap (80% of remaining usable) is therefore the **inline-vs-summary
threshold**, not a sizing guarantee. If a tool's output exceeds the cap
at runtime, the BatchSizer routes it through the summary path — which
keeps the inline cost bounded. The output is never truncated to a
partial inline form.

## Formula

Computed once per batch at `BatchSizer.run/2` entry. Stored on the ctx
under `:__usable_remaining__` and threaded through `cook/2` to
`apply_one_with_acc/3`.

```elixir
# ctx.context_limit flows from state.llm_metrics.context_limit (may be nil)

usable = ctx.context_limit
       - Estimator.estimate_messages(ctx.messages || [])
       - @preflight_reserve   # 8_192 tokens — reserved for the LLM's
                              # next response + tool_call overhead

default_cap = floor(usable * 0.80)   # the inline-vs-summary threshold

effective_cap(tc) = case tc.arguments["max_result_tokens"] do
  nil  -> default_cap                          # LLM didn't ask, use 80%
  n when is_integer(n) and n > 0 ->
    min(n, default_cap)                         # LLM asked for less
  _    -> default_cap                          # malformed → fall back
end
```

When `ctx.context_limit` is `nil` (degraded-but-hopeful path), no cap.
When `usable ≤ 0`, the preflight has already refused the batch, so this
branch is unreachable in practice.

## Per-tool behavior when the cap is exceeded

| Tool | Action when `content_size > effective_cap` |
|---|---|
| `execute_command` | Write full content to `<tmp>/exec-<rand>.txt`. Return `Command output of '<cmd>' (<N> tokens) saved to <path>.\n\n<head>` (existing `build_summary_with_size/4`). |
| `read_file` | Return `{:error, "File is X tokens which exceeds your requested limit of Y."}`. The LLM gets a structured error and can retry with a higher `max_result_tokens` or use `inspect_file` / `shell_cmd head/tail`. |
| `write_file` | Bounded output (`"Successfully wrote N bytes to <path>"`). Cap-exceeded is unreachable in practice. Falls through to the existing `keep full anyway` log. |
| `edit` | Bounded output (`"Replaced N occurrence(s) in <path>"`). Same as `write_file`. |
| `context` | Bounded output. Same as `write_file`. |

Only `execute_command` and `read_file` need explicit cap-exceeded paths.
The other three tools have bounded outputs by construction.

## Decision tree in `apply_one_with_acc/3`

```
For each tool result, in batch order:

1. content_size = Estimator.estimate(content) + per_message_overhead()

2. If effective_cap && content_size > cap + per_message_overhead():
     # Cap exceeded → route per-tool (see table above)
     For execute_command: write-to-tmp + path-and-head summary
     For read_file:        return error ToolResult with is_error: true
     For other tools:      log warning, keep full

3. Else (content fits the inline cap):
     If keep_full?(tc, acc, content_size):
       Return full content
     Else (rare — batch budget overflow post-preflight):
       For execute_command: write-to-tmp + path-and-head summary
       For other tools:      log warning, keep full
```

The cap check (step 2) is the **primary gate**. The batch-budget check
(step 3) is a secondary defense for cases where multiple tools in the
same batch collectively overflow — rare, because preflight has already
guaranteed space for the minimums.

## Helper signatures (planned)

```elixir
# Public — usable remaining context (excluding reserve)
@spec usable_remaining(map()) :: pos_integer() | nil

# Public — the effective cap for a single tool call
@spec effective_max_result_tokens(ToolCall.t(), map(), pos_integer() | nil) ::
        pos_integer() | nil

# Private — per-tool routing when the cap is exceeded
@spec handle_over_cap(ToolCall.t(), String.t(), pos_integer(), map(), map()) ::
        {{atom(), atom(), String.t()}, map()}
```

`ctx[:__usable_remaining__]` is computed once in `run/2` and read in
`apply_one_with_acc/3` via the ctx map. (Avoids threading a new
parameter through every helper.)

## File-by-file change list

### `lib/nest/agents/agent/batch_sizer.ex`
- Add `usable_remaining/1`, `effective_max_result_tokens/3`, `handle_over_cap/5`.
- Modify `run/2` to thread `__usable_remaining__` through ctx.
- Modify `apply_one_with_acc/3` to add the cap check at the top of the
  decision tree.
- No new truncation function. Existing `build_summary_with_size/4`
  is reused for `execute_command`.

### `lib/nest/llm/tool.ex`
- Update moduledoc to describe the new design (cap is inline-vs-summary
  threshold, 80% default, override-below, no truncation).
- Remove `max_result_tokens` from `defstruct` (was never consumed at
  runtime; the schema entry lives on `parameters_schema`, not the struct).
- Remove `max_result_tokens` from the `@type t` typespec.

### `lib/nest/tools.ex`
- Remove `max_result_tokens: ...` from each of the 5 Tool struct
  builders (`read_file_function`, `write_file_function`, `edit_function`,
  `shell_cmd_function`, `context_function`).
- Remove the 4 `@*_max_result_tokens` constants (`@default_max_result_tokens`,
  `@write_file_max_result_tokens`, `@context_max_result_tokens`,
  `@edit_max_result_tokens`).
- Update `max_result_tokens_schema/0` description: "Maximum tokens for the
  inline result. Default is 80% of the remaining usable context window.
  Lower this to force a path-and-head summary for `execute_command` or
  an error for `read_file`." Keep the schema entry — the LLM still
  needs to see the knob.

### `lib/nest/llm/tools.ex`
- Delete `default_max_result_tokens/2` — dead code, never called
  anywhere in `lib/` or `test/`.

### `test/nest/agents/agent/batch_sizer_test.exs`
Add 6 tests under a new `describe "max_result_tokens cap"` block:

1. `execute_command output exceeding 80% cap routes to summary path`
2. `LLM override below 80% forces summary even when output fits inline`
3. `LLM override above 80% is clamped to 80%`
4. `output below cap stays inline (no summary)`
5. `read_file exceeding cap returns error: "File is X tokens which exceeds your requested limit of Y."`
6. `no cap when context_limit is nil`

Existing tests should still pass — the cap check is additive (an
additional route before the existing keep-or-summarize decision).

### `test/nest/llm/tool_test.exs` (create if absent)
- Schema has `max_result_tokens` arg.
- Struct does NOT have a `max_result_tokens` field.
- `@type t` does NOT include `max_result_tokens`.

### `test/nest/tools_test.exs` (and friends like `tools_edit_test.exs`, `tools_inspect_file_test.exs`)
- Existing tests check `tool.max_result_tokens` — update them to check
  `tool.parameters_schema["properties"]["max_result_tokens"]` instead.

### `notes/extract-compaction-and-resumable-chat-turn.md`
Update the BatchSizer section with:
- The cap formula (`usable`, `default_cap`, `effective_cap`).
- The decision tree (full vs. summary, no intermediate truncation).
- The per-tool table.

### `notes/context-and-compaction.md`
Rewrite the "Per-tool max_result_tokens" section (lines 89-109) to
reflect the new design. The 8,192 default and 50% ceiling are gone;
the new spec is 80% of remaining usable, with override-below.

## Sequencing (for build-mode execution)

1. `lib/nest/llm/tool.ex` — docstring + struct cleanup
2. `lib/nest/tools.ex` — remove per-tool field + constants
3. `lib/nest/llm/tools.ex` — delete dead `default_max_result_tokens/2`
4. `lib/nest/agents/agent/batch_sizer.ex` — main work (cap formula,
   decision tree integration, per-tool routing)
5. `test/nest/agents/agent/batch_sizer_test.exs` — new tests
6. Existing schema tests — update assertions
7. Doc updates (both `notes/` files)
8. `mix precommit` — verify clean

## Open questions

- **`max_result_tokens` validation**: treat `nil`/missing as "use 80%
  default," integers ≤ 0 as "use 80% default" (invalid → fall back),
  positive integers as "use override (clamped to 80%)." Negative or zero
  values from a malformed LLM response fall back to default rather than
  raising an error. Document this in `effective_max_result_tokens/3`.
- **`read_file` error message wording**: `"File is X tokens which
  exceeds your requested limit of Y."` — matches user spec exactly.
  Confirm or tweak.