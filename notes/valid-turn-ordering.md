# Valid Turn Ordering

The provider wire protocols require valid message sequences. Anthropic
enforces strict `user ↔ assistant` alternation and requires every
`tool_use` to be immediately paired with a corresponding `tool_result` in
the following user message. OpenAI is more permissive but we target both.

Our internal roles and their Anthropic wire roles:

| Internal | Wire role |
|---|---|
| `{:system, _}` | `system` (top-level or array — valid anywhere) |
| `{:user, _}` | `user` |
| `{:assistant, _}` | `assistant` |
| `{:tool, _}` | `user` (contains only `tool_result` blocks) |

Anthropic accepts mid-conversation system messages, so system messages
have been the safe injection vehicle for notices (context warnings,
budget reminders, compaction suffixes). But some providers reject
mid-conversation system messages, and the `rewrite_late_system_messages`
workaround — wrapping them as user messages with a `[System notice: …]`
prefix — creates alternation violations: two consecutive `user` messages
when the preceding message is `{:tool, _}` (also wire `user`).

## Goal

Eliminate late system-message injection entirely. Replace with a
universal mechanism that always preserves valid wire alternation.

## Design

### 1. Tool messages carry text notices

Extend `{:tool, _}` messages (`%Tool{}` struct) to allow `%Part.Text{}`
alongside `%Part.ToolResult{}` in the `:parts` list. Text notices
(context warnings, budget reminders) attach directly to the next tool
response instead of being injected as separate messages.

Internal representation:
```
{:tool, %Tool{parts: [
  %Part.Text{text: "Context at 75%. Consider compacting."},
  %Part.ToolResult{tool_call_id: "call_1", name: "read_file", content: "..."},
  %Part.ToolResult{tool_call_id: "call_2", name: "shell_cmd", content: "..."}
]}}
```

No new message, no alternation breakage. The tool message is already
`role: "user"` on the Anthropic wire; text alongside tool results in the
same content block array is valid per the Anthropic API spec.

### 2. Provider formatters handle mixed tool parts

**Anthropic** (`anthropic_client.ex`): iterate all parts, dispatch
`Part.Text` → `{"type":"text",…}` and `Part.ToolResult` →
`{"type":"tool_result",…}`. Single `role: "user"` message with mixed
content blocks.

**OpenAI** (`openai_client.ex`): split parts — `Part.Text` →
`{"role":"user","content":…}` messages, `Part.ToolResult` →
`{"role":"tool","tool_call_id":…,"content":…}` messages. Already uses
`flat_map` so multiple messages per internal message work correctly.

**Mock** (`mock_client.ex`): switch to Anthropic single-message format.
This fixes a latent bug where the mock's `message_to_wire({:tool, _})`
returns a list but `format_request_payload` uses `Enum.map` (not
`flat_map`), producing nested lists in the API log for multi-tool-call
batches. Also fix `message_to_wire({:assistant, _})` from returning
`[map]` to returning `map` for consistency.

### 3. Deferred-attach injection replaces LateMessage

Delete `late_message.ex`. Remove `rewrite_late_system_messages` from
`ClientConfig`, `DotConfig`, and `ChatModel`.

Instead of immediately appending a separate message to the Agent's list,
set `pending_notice` on the ChatTurn state. The notice is consumed by
the next message constructor.

#### 3a. Attached to tool messages

`handle_tool_results` checks `state.pending_notice`. If set, it prepends
`%Part.Text{text: notice}` to the `{:tool, _}` parts before appending to
the Agent.

Both context warnings and budget reminders follow this path — they only
fire when tool sequences are active. By construction, the next message is
always a `{:tool, _}`.

#### 3b. Synthetic [user, assistant] pair for text-only injection

When `dispatch_batch` fires and `pending_notice` is set but there are no
pending tool results (the last LLM response was text-only), inject a
`[notice_user, ack_assistant]` pair into both the Agent's persistent
list and the LLM request messages.

```
[..., final_assistant_text,
 {:user, "Context at 75%. Consider compacting."},
 {:assistant, "Okay, no more expensive tool calls. I should consider explicitly compacting."}]
```

Both sides carry information — the assistant ack primes the model's
awareness for the next real response.

### 4. Context warning pair content

Thresholds fire at most once between compactions (existing behavior):

| Threshold | User message | Assistant ack |
|---|---|---|
| 25% | `"Context at 25%."` | `"Okay, that's plenty of space."` |
| 50% | `"Context at 50%."` | `"Okay, I should consider conserving tokens."` |
| 75% | `"Context at 75%."` | `"Okay, no more expensive tool calls and I should consider explicitly compacting."` |

When attached to a tool message (single `Part.Text`, no ack needed — the
LLM's next assistant IS the ack): use condensed text like
`"Context at 75%. Consider compacting via the context tool."`

### 5. Budget reminder pair content

The budget reminder fires with ≤2 rounds remaining and only during tool
sequences, so it always attaches to a tool message (no pair needed).

Condensed text for tool attachment:
- 2 remaining: `"2 tool call rounds remaining. Plan your remaining tool use carefully."`
- 1 remaining: `"Last tool call round. Provide your final response after this tool."`

### 6. Compaction suffix as user message

Render the `[mode: compact]` suffix as `{:user, _}` instead of
`{:system, _}` (`tokens/compactor.ex:281-289`). No `LateMessage.rewrap`
needed.

### 7. Synthetic assistant bridge in compactor's request

When the compaction suffix is a user message and the last message before
it is `{:tool, _}` (wire `user`), appending the suffix creates `user →
user` — an alternation violation.

`dispatch_compaction` handles this by injecting a synthetic text-only
`{:assistant, _}` between the conversation messages and the suffix, but
**only in the compactor's LLM request** (not the Agent's persistent
message list). The bridge is visible in the compactor's API log.

```
# Request messages (compactor's LLM call):
[..., preceding_tool_results,                       # wire: user
 {:assistant, "Let me pause to summarize."},         # wire: assistant ✓
 {:user, "[mode: compact] Summarize in N tokens."}]  # wire: user ✓
```

The synthetic assistant is a simple text-only message:
```
{:assistant, %Assistant{parts: [%Part.Text{text: "Let me pause to summarize."}]}}
```

### 8. Preflight: add alternation validation

Extend the existing `Preflight.walk_*` (used by MockClient) to track
`last_wire_role` alongside the `:free | {:need, ids}` state. New error
kind `:alternation_violation` fires for consecutive `user` or
`assistant` wire roles. `:system` messages are ignored for alternation.
`{:tool, _}` counts as wire role `user`.

This catches injection bugs in tests before they reach the provider.

### 9. Subagent: strip trailing tool_use from copied messages

Extract `drop_trailing_unpaired_tool_call` from
`iteration.ex:184-196` into a shared location (e.g.,
`Nest.Messages.MessageList` utility module).

Apply in `supervisor.ex:build_child_attrs` before copying
`preloaded_messages` to the child agent. The child inherits the parent's
conversation context, but the parent may have an unpaired
`{:assistant, _}` with `Part.ToolUse{}` blocks at the end of its message
list (the `clone_agent` tool call itself). The tool_use has no
corresponding `tool_result` yet — the child IS the result. Stripping
prevents the child's first LLM call from being rejected with
Anthropic error 2013 ("tool call result does not follow tool call").

The trait is also a latent fix for a race: the async
`{:tool_calls_received, _}` cast and the sync `{:clone_agent_request,
_}` call arrive from different BEAM processes with no ordering guarantee.
If the cast hasn't been processed when the call copies messages, the
unpaired assistant might not even be in the list — but we strip anyway
for the common case where it is.

### 10. Timing consistency

Currently `maybe_inject_budget_reminder` appends to the Agent's list
**before** `get_messages_with_cancelled` (so the reminder is in the
current request), while `inject_context_warning` appends **inside**
`dispatch_batch` (next request). With deferred-attach, both follow the
same pattern: set `pending_notice`, consumed by the next message
constructor.

## Files

### Delete
- `lib/nest/agents/agent/chat_turn/late_message.ex`

### Modify
- `lib/nest/messages/tool.ex` — allow `Part.Text` in parts, update builder
- `lib/nest/messages/message.ex` — `to_json` handles `Part.Text` in tool
- `lib/nest/llm/anthropic_client.ex` — tool message formatter: dispatch
  `Part.Text` to text blocks, `Part.ToolResult` to `tool_result` blocks
- `lib/nest/llm/openai_client.ex` — tool message formatter: emit
  `Part.Text` as `role:"user"` messages, `Part.ToolResult` as
  `role:"tool"` messages
- `lib/nest/llm/mock_client.ex` — switch to Anthropic single-message
  format; fix `message_to_wire({:assistant,_})` list→map
- `lib/nest/llm/preflight.ex` — add alternation validation; handle new
  text parts in tool messages (no functional impact, already ignores
  non-ToolResult parts)
- `lib/nest/llm/client_config.ex` — remove `rewrite_late_system_messages`
- `lib/nest/dot_config.ex` — remove `rewrite_late_system_messages` parsing
- `lib/nest/chat_model.ex` — remove `rewrite_late_system_messages` population
- `lib/nest/agents/agent/chat_turn/context_reminder.ex` — return raw
  text, define pair content, remove `LateMessage` dependency
- `lib/nest/agents/agent/chat_turn/budget_reminder.ex` — return raw text,
  remove `LateMessage` dependency
- `lib/nest/agents/agent/chat_turn/iteration.ex` —
  `inject_context_warning` sets `pending_notice` instead of appending;
  `dispatch_compaction` injects synthetic assistant bridge when needed
- `lib/nest/agents/agent/chat_turn.ex` —
  `maybe_inject_budget_reminder` sets `pending_notice`;
  `handle_tool_results` consumes `pending_notice` and attaches to tool
  message parts
- `lib/nest/agents/agent/chat_turn/messages.ex` — `tool/1` accepts
  optional notice text
- `lib/nest/agents/agent/chat_turn/state.ex` — add `pending_notice` field
- `lib/nest/agents/agent/compaction/trigger.ex` — remove
  `LateMessage.rewrap` call
- `lib/nest/tokens/compactor.ex` — `wrap_request_suffix` returns
  `{:user, _}` instead of `{:system, _}`
- `lib/nest/agents/supervisor.ex` — `build_child_attrs` strips trailing
  unpaired tool_use from `preloaded_messages`
- JS/React: handle `Part.Text` display in tool response blocks

### New
- Shared utility for `drop_trailing_unpaired_tool_call` (extracted from
  `iteration.ex`, used by both `dispatch_compaction` and
  `supervisor.build_child_attrs`)
- Synthetic assistant message builder (used by bridge and pair injection)
