# Normalize Tool Names + Split the Context Tool

## Why

Tool names use an inconsistent mix of underscores, bare barewords, and a slash
(`/`). The slash in particular isn't widely supported in tool-name APIs, so the
four `agents/*` tools are at risk with providers that want to be lame. We're
normalizing every tool name to the **kebab-case** convention (single
`category-tool` words, no slashes, no underscores), and taking the opportunity
to split `context` — which is secretly two tools with completely different
execution paths — into two clearly-named tools.

`context` (a single lowercase word, no slash/underscore) already fits the
"lame API" constraint; it only changes because we're splitting it.

## New tool names

| Old name | New name | Notes |
|----------|----------|-------|
| `read_file` | `file-read` | |
| `write_file` | `file-write` | |
| `edit` | `file-edit` | |
| `inspect_file` | `file-inspect` | |
| `shell_cmd` | `shell-cmd` | |
| `agents/spawn` | `agents-spawn` | slash removed |
| `agents/list` | `agents-list` | slash removed |
| `agents/query` | `agents-query` | slash removed |
| `agents/archive` | `agents-archive` | slash removed |
| `context` (action: `check`) | `context-check` | split — normal read-only tool |
| `context` (action: `compact`) | `context-compact` | split — intercepted control tool |

## The two `context` tools

`context` is really two tools today, distinguished by the `action` arg:

1. **`check`** — a normal, read-only tool. Goes through the standard
   BatchSizer → execute path. Currently a no-op stub that returns
   `"Context request received."`. We're giving it **real usage stats** so the
   LLM can actually use it.
2. **`compact`** — a **control-flow tool, not a normal tool**. It never
   reaches the tool worker. It is intercepted in `ResponseHandler` ahead of
   execution: it must be the *sole* call in a batch, and it exits with a
   `:compact_tool` continuation → `:needs_compaction` → the Agent runs the
   compactor.

Splitting them into distinct named tools is a simplification: the `action` arg
disappears from both, `context_compact?/1` matches on the tool *name* instead
of an `action` value, and the existing "must be sole in batch" refusal keys off
the compact tool's name.

### `context-check` output

Computes real stats from the tool context map (`messages`, `context_limit`),
using the same math as `BatchSizer`/`CapCalculator`:

- **used** — `ConversationSize.size(messages)` (real-valued tokens), rounded.
- **limit** — `context_limit`.
- **pct** — `round(used / limit * 100)` (reserve not subtracted).
- **usable remaining** — `CapCalculator.usable_remaining(%{context_limit: limit, messages: messages})`
  (== `context_limit − current_messages − response_budget`, floor at 0). This is
  the exact budget the BatchSizer will enforce on tool results, so the LLM is
  told precisely how much it can spend.
- Falls back to `"Context: N messages."` when `context_limit` is unknown
  (CapCalculator raises on nil/non-positive, so we guard).

## Changes by file

### Part A — the 9 dash renames

Elixir lib:
- `lib/nest/tools.ex` — `get_function/3` dispatch clauses, `sub_agent_tool_function`
  heads, tool `name:` fields, comments.
- `lib/nest/tools/file_tools.ex` — `name:` for read/write/edit.
- `lib/nest/tools/inspect_file.ex` — `name:`.
- `lib/nest/agents/agent/tool_loop.ex` — the four `agents/*` matchers
  (`sub_agent_tool?/1`, `run_sub_agent_tool/2`), `build_tool_result` names,
  log strings.
- `lib/nest/agents/agent/batch_sizer.ex` — `shell_cmd`, `read_file` matches.
- `lib/nest/agents/agent/batch_sizer/projected_size.ex` — read_file /
  shell_cmd / write_file / edit / inspect_file clauses.
- `lib/nest/agents/agent/batch_sizer/file_policy.ex` — `write_file`.
- `lib/nest/agents/agent/handlers/llm_stream_handler/file_access.ex` —
  `read_file`, `write_file`.
- `lib/nest/messages/message_list.ex` — `agents/spawn` (extract + build fork).
- `lib/nest/llm/mock_client.ex` — `shell_cmd`.

Elixir tests:
- `test/nest/tools_test.exs`, `tools_edit_test.exs`, `tools_inspect_file_test.exs`,
  `tools_defensive_dispatch_test.exs`, `agents/agent/sub_agent_tools_test.exs`,
  `agents/agent_tools_test.exs`, `vocations_modes_test.exs`, `persistence_test.exs`,
  `messages/streaming_test.exs`.
- `test/support/agent_test_helpers.ex` — `@agents_tools` list + the
  `programmer_vocation_id_for_test/0` / `vocation_id_for_test/0` tools arrays.
- `test/support/persistence_test_helpers.ex` — tools array.

JS:
- `assets/js/components/DelegatedTaskBlock.jsx` — the `c.name === "agents/spawn"`
  filter → `"agents-spawn"` (and comments).
- Tests with hardcoded names: `pages/ChatPage.test.jsx`, `components/ToolCalls.test.jsx`,
  `store/index.test.js`, `utils/messageParts.test.js`, `utils/formatMessage.test.js`.
- `ToolCalls.jsx` / `messageParts.js` display the tool `name` passed in, so
  `Using tool: file-read`, etc. update automatically — no label mapping needed.

Prose / seeds:
- `priv/repo/seeds.exs` — tool arrays.
- `scripts/minimax-chat-probe.exs` — tool names + prose.
- Notes under `notes/`.

### Part B — split `context` into `context-check` + `context-compact`

- `lib/nest/tools.ex` — replace `context_function/0` with
  `context_check_function/0` (`context-check`, schema `max_result_tokens`,
  real-stats function) and `context_compact_function/0` (`context-compact`,
  schema `focus`, stub — intercepted, never invoked).
- `lib/nest/agents/agent/batch_sizer.ex` — `do_execute` widens the tool context
  passed to `LLMTools.execute_one/3` from `%{caps: ctx.caps}` to
  `%{caps: ctx.caps, messages: ctx.messages, context_limit: ctx.context_limit}`;
  also update the preflight refusal text `context.compact` → `context-compact`.
- `lib/nest/agents/agent/tool_loop.ex` — `context_compact?/1` matches
  `%ToolCall{name: "context-compact"}`; `strip_context_compact/1` unchanged.
- `lib/nest/agents/agent/chat_turn/response_handler.ex` — `compact_only?/1` and
  `contains_compact?/1` match `name: "context-compact"`;
  `build_synthetic_compact_result` emits `name: "context-compact"`.
- `lib/nest/agents/agent/chat_turn/messages.ex` —
  `refuse_context_compact_co_batch` message text → `context-compact`.
- `lib/nest/agents/agent/chat_turn/context_reminder.ex` — p75 prose →
  `context-compact`.
- `lib/nest/agents/agent/chat_turn.ex` — comments re `context.compact` →
  `context-compact`.
- `lib/nest/agents/agent/compaction/trigger.ex` — comment prose.
- `lib/nest/agents/agent/chat_turn/iteration.ex` — comment prose.
- `lib/nest/agents/agent/batch_sizer/projected_size.ex` — rename the `context`
  clause → `context-check` (same bounded estimate); no clause for
  `context-compact` (it's stripped before preflight anyway).
- `lib/nest/agents/agent/introspection_handler.ex` / `broadcasts/usage.ex` /
  `tokens/pre_flight.ex` — only prose/comments; update for consistency.

Part B tests:
- `test/nest/agents/agent_compaction_test.exs`, `agent_chat_turn_iteration_test.exs`
  — the `name: "context"` + `arguments: %{"action" => "compact"}` shapes become
  `name: "context-compact"` with no action.
- `test/nest/tools_test.exs` — `get_function("context", ...)` → `"context-check"`
  and `"context-compact"`; the `for name <- [...]` list updated.
- `test/support/agent_test_helpers.ex` / `persistence_test_helpers.ex` —
  `tools:` entries from `"context"` → `"context-check", "context-compact"`.
- `priv/repo/seeds.exs` — `"context"` → `"context-check", "context-compact"`.
- New tests: `context-check` real-stats path (normal usage + usable remaining,
  and unknown-limit fallback).
- Update the many `tools: ["context"]` call sites in tests (agent_compaction,
  agent_recovery, supervisor_spawn, supervisor_persistence, agent_overflow_integration,
  agent_persistence, agent_oversized_system, agent_compaction_preflight,
  agent/sub_agent_tools_test, agent/system_prompt_depth_filter_test, etc.).
  Whether each becomes `["context-check", "context-compact"]` depends on what the
  test exercises; compact-only tests can use just `["context-compact"]`.

## Display / persisted history

- **UI display** shows the raw tool `name`, so after the rename the UI shows
  `Using tool: file-read`, `agents-spawn`, etc. No label mapping required.
- **Persisted message history** already written with the old names keeps showing
  old names until re-rendered/replayed — cosmetic only, no data fix required.

## Verification

- `mix precommit` — read the *full* output.
- `mix assets.check` (biome).
- `mix assets.test` (JS tests).
- New/updated tests for the `context-check` real-stats path and the compact rewire.

## Not in scope

- Changing the persisted DB message-part `name` values (cosmetic; see above).
- Prettier human labels for tool display (raw name shown).
