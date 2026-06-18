# Context Tracking & Compaction

Multi-layer response to context overflow. The agent can run out of
context because:

- Tool results are too big (a `cat` on a log file, `read_file` on a
  large source file)
- The conversation grows over many turns
- A single LLM call returns a long response

This plan introduces token estimation, per-tool caps, a per-tool-call
budget loop, and a two-pass compaction algorithm — all orchestrated
through a new `Nest.Tokens.*` module family and a `history` field on
the agent.

## Goals

- Never silently overflow the context window.
- Always leave room for a future compaction.
- Tool results are bounded per-call; multi-call sequences degrade
  gracefully (truncate, skip the rest, tell the LLM).
- Compaction is predictable: turn-boundary, KV-cache friendly, two-pass
  when needed.
- The full conversation history is preserved in the agent's `history`
  field; the chat UI can show it collapsed with expansion.

## Locked design decisions

| # | Decision | Value |
|---|---|---|
| 1 | Compaction reserve | 8,192 tokens, per-model config, 32k+ only |
| 2 | Token estimator | `tiktoken_elixir` cl100k_base + 20% safety multiplier |
| 3 | Multi-call tool loop | `Nest.Tokens.BudgetPlanner`, dynamic per-iteration overhead |
| 4 | Per-tool `max_result_tokens` | 8,192 default, LLM override ≤ 50% of context |
| 5 | Compaction trigger | Auto pre-flight + LLM-callable `compact_context` tool |
| 6 | Mid-sequence exhaustion | Skip the rest of the batch |
| 7 | LLM awareness | Truncation note + skip message |
| 8 | Compaction model | Same as chat |
| 9 | Compaction prompt | Freeform prose, preserve goals/facts/decisions/TODOs |
| 10 | Pre-flight location | Just before every LLM call |
| 11 | Compaction tool result | Returns confirmation |
| 12 | Compaction algorithm | Two-pass, KV-cache optimized |
| 13 | Pass 1 | Summarize pre-last-user → head summary |
| 14 | Pass 2 trigger | If head + last_user + responses > 25% of context |
| 15 | Pass 2 | Summarize the response sequence → tail summary |
| 16 | Post-compact state | `system` + `head_summary` + `last_user` + (`tail` or `tail_summary`) |
| 17 | History model | Two lists: `messages` (active) + `history` (archived) |
| 18 | On compaction | `messages` → `history`; `messages` ← new compacted state |
| 19 | Full history for UI | `history ++ messages` |
| 20 | Message index | Monotonic, never reused; post-compaction messages get new indices |
| 21 | Compaction marker | `{:compaction, _}` variant, lives in `history` only |
| 22 | Summary placement | As messages |
| 23 | UI for archived | Collapsed by default, expandable |
| 24 | Compaction flow | Encapsulated in a Task (GenServer never blocks) |
| 25 | In-progress state | Disallow compaction while streaming |

## Token budget math

```
context_limit                    # from config.toml or probed (per model)
reserve        = 8192            # from config.toml (per model)
working        = context_limit - reserve
estimated_used = estimate(history ++ messages) + (streaming_acc_text | 0)
remaining      = working - estimated_used

# Per-iteration overhead in a multi-tool sequence:
unprocessed_count  = tool_calls remaining in batch
future_skip_cost   = unprocessed_count * skip_response_size  # ~70 tokens
budget_for_this    = remaining - per_call_overhead - future_skip_cost
# where per_call_overhead = 200 (wire format) and skip_response_size = 70
```

When `remaining` would be exceeded by a tool result, three outcomes
in order of preference:

1. **Fits as-is** → include the full result.
2. **Fits after head-truncation** (kept chunk ≥ 256 tokens) → truncate
   to fit, append a note: `[truncated: original ~N tokens, kept first
   ~M tokens]`.
3. **Even truncated is too small** → replace with a skip response:
   `[skipped: tool 'shell_cmd' was not executed — only ~N tokens of
   context budget remain. Reformulate the request (e.g. use a more
   specific path, pipe through a filter, or split into smaller calls)
   before retrying.]`

If `budget_for_this < min_skip_trigger` (200 tokens) for the current
call, skip *this and all remaining* unprocessed calls in the batch.

## Per-tool `max_result_tokens`

A field on `Nest.LLM.Tool`, set per tool definition, with a uniform
default of 8,192. The LLM can override on a per-call basis by passing
`max_result_tokens` as a call arg. The effective cap is:

```
effective_cap = case tool_call.args["max_result_tokens"] do
  nil      -> tool.max_result_tokens        # default
  override -> min(override, context_limit / 2)  # capped at 50% of context
end
# Then: truncate result to effective_cap if larger
```

The 50% ceiling prevents a single tool call from blowing half the
context window. Tools get:

| Tool | Default | Rationale |
|---|---|---|
| `read_file` | 8,192 | Most source files fit; huge ones (generated, lockfiles) get truncated |
| `shell_cmd` | 8,192 | Same; tool description steers LLM to be specific with commands, no grep/head nudging |
| `write_file` | 256 | Returns a small fixed-size ack; cap is a no-op |

The cap is enforced at the tool-execution layer (BudgetPlanner) before
the context-budget check. Two layers of defense.

## Compaction algorithm

Two passes, KV-cache optimized (system prompt is stable across all
LLM calls in an agent loop, so prompt caching can hit):

```
function compact(messages, context_limit, llm_call):
  system     = messages[0]                    # first message (always system)
  last_user  = last {:user, _} in messages
  responses  = messages after last_user
  head       = messages between system and last_user

  # Pass 1: head summary (system + head are the cache prefix)
  head_summary = llm_call(system, head)

  # Size check: does the recent slice fit in 25% of context?
  head_tokens  = estimate(head_summary)
  tail_tokens  = estimate(last_user) + estimate(responses)
  recent_total = head_tokens + tail_tokens

  if recent_total <= 0.25 * context_limit:
    new_messages = [system, head_summary, last_user] ++ responses
  else:
    # Pass 2: tail summary (shares [system, head_summary] prefix)
    tail_input   = [system, head_summary, last_user] ++ responses
    tail_summary = llm_call(system, tail_input)
    new_messages = [system, head_summary, last_user, tail_summary]

  # Move old messages to history
  archive(messages)             # messages → agent.history
  return new_messages
```

The 25% threshold keeps "what happened most recently" cheap to keep
verbatim; it triggers pass 2 only when the recent slice itself is
large.

**Compaction prompt** (sent on both passes):

> Produce a concise prose summary preserving: the user's current goal,
> key facts established, decisions made, and any unresolved TODOs.
> Drop redundant tool outputs and resolved sub-tasks. Target under
> 4,000 tokens.

## History model

Agent state holds:

```
messages  :: [Message.t()]   # active, LLM-visible
history   :: [Message.t()]   # archived; full sequence = history ++ messages
```

On compaction:

1. `history = history ++ messages` (current messages appended to history)
2. `messages = <new compacted state>` (the result of compact/2)
3. Each new message gets the next available index, continuing the
   monotonic sequence (so if history has 8 messages, new messages
   start at index 8).

**Compaction marker** is a `{:compaction, %{...}}` tuple appended to
`history` (not `messages`) at the boundary, recording the archived
range and timestamps. The chat UI renders the marker as a divider
with a "show N archived messages" expand button.

**Full history reconstruction** for the UI:

```elixir
defp full_history(agent), do: agent.history ++ agent.messages
```

## Compaction flow

- The agent GenServer never blocks.
- The pre-flight check runs at the start of every LLM call site:
  - Top of `handle_chat/3` (first LLM call of a turn)
  - Top of `build_tool_pair/3`'s recursive continuation
  - Inside the `compact_context` tool execution
- The pre-flight is a pure function: `estimate(current_size) >=
  context_limit - reserve - projected_input` → "needs compaction".
- If compaction is needed, the pre-flight spawns a `Task` that runs
  the two-pass algorithm. The Task sends a message back to the
  GenServer when done; the GenServer then proceeds with the original
  LLM call.

```elixir
def handle_cast({:chat, content, mode}, state) do
  state = %{state | messages: state.messages ++ [user_msg]}

  if pre_flight_needs_compact?(state) do
    spawn_compaction_task(state, :chat_continuation, {content, mode})
  else
    spawn_chat_task(state, content, mode)
  end
end

def handle_info({:compaction_done, new_state, continuation}, state) do
  new_state = %{state | messages: new_state.messages,
                       history: new_state.history}
  case continuation do
    {:chat_continuation, {content, mode}} ->
      spawn_chat_task(new_state, content, mode)
    ...
  end
end
```

## `compact_context` tool

```elixir
%Tool{
  name: "compact_context",
  description: "Replace the conversation history with a summary to free up
                context budget. Use this when you notice previous tool
                results were truncated or skipped due to context limits.",
  parameters_schema: %{
    "type" => "object",
    "properties" => %{
      "focus" => %{
        "type" => "string",
        "description" => "What to preserve in the summary. Defaults to a
                          balanced summary of all messages."
      }
    }
  },
  max_result_tokens: 256,
  function: fn args, context -> compact_context_impl(args, context) end
}
```

Tool execution:
1. Run the two-pass compaction
2. Append the previous `messages` to `history`
3. Set `messages` to the compacted state
4. Return a confirmation: `"Compacted N messages into a summary. You
   now have ~M tokens of working space."`

## In-progress state during compaction

Compaction is **disallowed while streaming**. The pre-flight check
inspects `state.streaming_acc` — if non-nil, the pre-flight is a no-op
(streams must finish first; pre-flight will re-run on the next call).
The `compact_context` tool execution also checks this; the LLM
calling the tool mid-stream triggers the tool call which interrupts
the stream, at which point streaming_acc is reset before the tool
runs.

`pending_api_logs` and `api_log_sequences` are preserved across
compaction (no relation to message indices in the new design).

## Code surface

### New modules

```
lib/nest/tokens/estimator.ex         # tiktoken + 20% safety
lib/nest/tokens/budget_planner.ex    # per-tool loop with budget checks
lib/nest/tokens/truncate.ex          # head truncation with note
lib/nest/tokens/skip_response.ex     # synthetic skip reply
lib/nest/tokens/compactor.ex         # two-pass algorithm
lib/nest/messages/compaction.ex      # {:compaction, _} marker
```

### Modified modules

```
lib/nest/llm/tool.ex                       # +max_result_tokens field
lib/nest/tools.ex                          # tool defs use new field;
                                          # +compact_context tool
lib/nest/agents/agent.ex                   # +history field,
                                          #  BudgetPlanner wiring,
                                          #  pre-flight, compaction
                                          #  task orchestration
lib/nest/agents.ex                         # expose history + info
lib/nest_web/channels/agent_channel.ex     # broadcast chat:compaction
lib/nest/messages/message.ex               # support {:compaction, _}
mix.exs                                    # +tiktoken_elixir
```

### New React components

```
assets/js/components/CompactionMarker.jsx
assets/js/components/CollapsedHistory.jsx
```

### Modified React

```
assets/js/store/index.js         # history + compaction state
assets/js/channels.js            # chat:compaction handler
assets/js/pages/ChatPage.jsx     # render marker + collapsed history
```

## Implementation order

1. **Estimator + budget arithmetic** — `Nest.Tokens.Estimator` with
   `tiktoken_elixir`. Pure functions: `estimate/1`, `estimate/2`
   (list of messages), context budget calc, per-call overhead. Unit
   tests.

2. **BudgetPlanner** — per-tool loop pulling in `Truncate` and
   `SkipResponse` helpers. Unit tests covering: fits as-is,
   truncates, skips, cascades skip to remaining, multiple tool
   calls with mixed outcomes.

3. **Wire BudgetPlanner into the agent** — swap
   `LLMTools.execute/3` in `build_tool_pair/3`. Add
   `max_result_tokens` schema to the three existing tools. Frontend
   pass-through. Integration tests showing truncate/skip behaviors.

4. **Per-tool `max_result_tokens` field** — add to `Nest.LLM.Tool`,
   update tool defs. No behavior change yet, just plumbing +
   schema docs.

5. **Pre-flight check + 25% trigger** — pure function. Hook into
   `handle_chat/3` and the tool-pair recursion. Tests.

6. **Compactor module** — two-pass algorithm. Pulls in `Estimator`,
   makes LLM calls. Unit tests with mock LLM.

7. **Wire Compactor into the agent** — replace direct LLM calls with
   pre-flight + maybe-compact + call. Tests for both paths.

8. **`compact_context` tool** — add the tool definition, wire into
   the pre-flight call. Tests.

9. **History field + compaction marker** — add `history` to agent
   state, marker struct, message-format support, broadcast
   `chat:compaction`. Backend tests.

10. **Frontend: store + channel + UI** — store tracks `history` per
    agent, channel handles `chat:compaction`, components render the
    marker + collapsed history. Component tests.

## Edge cases

- **Compaction itself overflows**: prevented by the design — the
  pre-flight check never lets `messages` exceed `context_limit -
  reserve`, so the compaction call (which is an LLM call with input
  = full current messages) always has room for its output.
- **Tiny models (< 32k)**: out of scope per the locked decision.
- **Empty message history**: pre-flight is a no-op; compaction
  returns `[system]` if there's nothing else to compact.
- **No last user message**: not possible — every chat turn starts
  with a user message.
- **Streaming interrupted by `compact_context` tool call**: the
  stream ends, the accumulator resets, the tool runs, the LLM
  resumes from the compacted state on its next turn.
- **`max_result_tokens` not in tool args**: use the tool's default.
- **`max_result_tokens` higher than 50% ceiling**: clamped to
  `context_limit / 2`.
- **Tool returns binary data** (not string): coerce to string
  before estimation.

## Open follow-ups (not in this plan)

- Persistence: the `messages`/`history` fields are in GenServer
  state only. Persisting them across agent restarts is a separate
  effort.
- Cost tracking: per-turn cost (input/output tokens × model price)
  is not yet computed.
- Multi-agent context sharing: how agents in a workflow share
  context.
- Configurable compaction threshold (currently fixed at 25% of
  context). Could become per-vocation.
