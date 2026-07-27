# Valid Turn Ordering

The provider wire protocols require valid message sequences. Anthropic
enforces strict `user ↔ assistant` alternation and requires every
`tool_use` to be immediately paired with a corresponding
`tool_result` in the following user message. OpenAI is more permissive but we target both.

Our internal roles and their Anthropic wire roles:

| Internal | Wire role |
|---|---|
| `{:system, _}` | `system` (top-level or array — valid anywhere) |
| `{:user, _}` | `user` |
| `{:assistant, _}` | `assistant` |
| `{:tool, _}` | `user` (contains only `tool_result` blocks) |

## Design

The notice-injection mechanism has two cases, each producing a
synthetic pair shape `[assistant(attention), user(notice)]`. The
mechanism is generic — the attention and notice text come from a
`%{kind, attention, notice}` spec produced by each trigger source.
New notice types just add a new spec-producing function; the
injection point iterates the list.

### Case 1: User message arrival (trailing assistant is text-only)

When the user sends a message and the trailing assistant is text-only
(turn ended, status is `:idle`), the pipeline injects a
`[user(notice), assistant(ack)]` pair before the real user message.
Wire: `assistant, user(notice), assistant(ack), user(real)`. Valid
alternation.

**Guard:** the `else` branch in `inject_notice/3` must NOT fire when
the trailing assistant carries an unpaired `Part.ToolUse{}` (in-flight
tool call). In that case the pair would land between the `tool_use`
and the upcoming `tool_result`, breaking Anthropic's pairing invariant
(`400 (2013)`). The threshold is marked crossed but the injection is
deferred to Case 2.

### Case 2: LLM response construction (ResponseHandler)

When the LLM's response is being assembled (streaming finalize or
`tool_calls_received` handler), the response handler collects notice
specs from all trigger sources and injects each as a synthetic pair
immediately before the assistant message.

#### Notice specs

Each trigger source produces a `%{kind, attention, notice}` map (or
`nil` if the source didn't fire):

| Source | `kind` | `attention` | `notice` |
|---|---|---|---|
| Context-usage threshold (25%/50%/75%) | `:context` | `"Context?"` | `ContextReminder.format/3` full text |
| Tool-call budget reminder (remaining ≤ 2) | `:budget` | `"Tool limit?"` | `BudgetReminder.notice_text/1` text |

The attention text is type-specific — it's the LLM's signal for which
notice is being delivered. New notice types add a new spec-producing
function with their own attention text.

#### Back-to-back: both fire on the same iteration

When both the context threshold and the budget reminder fire on the
same LLM response, `ResponseHandler.collect_case2_specs/2` returns
`[budget_spec, context_spec]` and both pairs are injected. The LLM
sees all four extra messages; the UI shows what was sent (we don't
lie to the user). The `active_message_index` correction is
`+ 2 * length(specs)` — the `active_message_index` is set to the
pre-injection expected index, so it's advanced to the actual index
of the LLM's response after all injected pairs.

#### Spec collection priority

`collect_case2_specs/2` checks the budget first (via
`state.pending_notice` — set by `chat_turn.maybe_inject_budget_reminder/1`),
then the context (via `ContextReminder.spec/3`). The order of the
returned list is the injection order. Budget appears before context
because the budget is the more urgent signal.

#### Pair shape

Each spec produces:
```
[
  {:assistant, %Assistant{parts: [%Part.Text{text: attention}]}},
  {:user, %User{parts: [%Part.Text{text: notice}]}}
]
```

The `assistant(attention)` is the attention-grabber. The `user(notice)`
carries the full format text. The LLM's response is the implicit ack
(per design §4: "the LLM's next assistant IS the ack").

### Budget reminder (detail)

The budget reminder (`ChatTurn.maybe_inject_budget_reminder/1`) sets
`state.pending_notice` at the start of each iteration when remaining
iterations ≤ 2. The response handler consumes it via
`BudgetReminder.spec_from_pending/1` in Case 2. `state.pending_notice`
is cleared after the pair is injected (in
`ResponseHandler.maybe_inject_case2_notice/2`).

No more attaching `Part.Text` to `{:tool, _}` messages — that broke
OpenAI wire format (the formatter destructured mixed parts into
separate wire messages, separating the `tool_result` from its
`tool_use`).

### User-during-tool-execution rejection

The channel layer (`agent_channel.ex`) and the agent's `handle_cast`
both reject user messages that arrive while the agent is `:streaming`
or `:executing_tools`. The frontend already disables the input in this
state, so this is a defense-in-depth backstop for programmatic API
calls, multi-client races, and stale UI state.

Rejecting at the boundary prevents the interleaving that would otherwise
break wire alternation and tool_use/tool_result pairing.

## Files

### Modify
- `lib/nest/agents/agent/chat_pipeline.ex` — guard `inject_notice/3`
  `else` branch
- `lib/nest/agents/agent/chat_turn/response_handler.ex` — Case 2
  spec collection and list-based injection via `inject_specs/2`;
  `collect_case2_specs/2` is the public entry point
- `lib/nest/agents/agent.ex` — defense-in-depth guard in `handle_cast`
- `lib/nest_web/channels/agent_channel.ex` — reject messages for
  `:streaming` / `:executing_tools`
- `lib/nest/agents/agent/chat_turn.ex` — remove tool-attached path;
  budget reminder sets `pending_notice` (consumed by response handler)
- `lib/nest/agents/agent/chat_turn/messages.ex` — `tool/1` no longer
  takes notice text
- `lib/nest/messages/tool.ex` — `parts: [Part.ToolResult.t()]` (no
  `Part.Text` union)
- `lib/nest/llm/anthropic_client.ex` — remove `Part.Text` clause from
  `tool_part_to_wire/1`
- `lib/nest/llm/openai_client.ex` — remove `text_msgs` branch from
  `message_to_wire({:tool, _})`
- `lib/nest/llm/mock_client.ex` — remove `Part.Text` clause from
  `message_to_wire({:tool, _})`
- `lib/nest/agents/agent/chat_turn/context_reminder.ex` — add
  `spec/3` returning the context notice spec
- `lib/nest/agents/agent/chat_turn/budget_reminder.ex` — add
  `spec/1` and `spec_from_pending/1` returning the budget notice
  spec
- `lib/nest/agents/agent/introspection_handler.ex` — add
  `:get_crossed_thresholds` handler

### No change
- `lib/nest/llm/preflight.ex` — alternation and pairing validation
  already in place (MockClient only)
- `lib/nest/agents/supervisor.ex` — `drop_trailing_unpaired_tool_call`
  already in `MessageList` utility
- `lib/nest/agents/agent/chat_turn/iteration.ex` — `dispatch_compaction`
  already drops trailing unpaired tool calls
- `lib/nest/tokens/compactor.ex` — compaction suffix already as
  `{:user, _}`; synthetic bridge already in place
