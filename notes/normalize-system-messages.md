# Normalize System Messages in the LLM-Bound List

## Problem

The current code has two systemic bugs and one architectural smell
surrounding how system messages are sent to the LLM:

1. **The "X rounds remaining" reminder is broken.** The warning that
   fires when the LLM is approaching the `max-tool-iterations` cap
   was being appended to `ctx.system_prompt` on every iteration that
   crossed the threshold (`lib/nest/agents/agent/llm_runner.ex:256-266`).
   The system prompt should be stable per turn — mutating it mid-flight
   is exactly the kind of thing that breaks prompt caching on providers
   that hash the system prompt. Inspection of the LLM request payloads
   (e.g. `notes/max-tool-calls.log`) confirms the warning never actually
   reaches the LLM in the wire format.

2. **The max-iterations final call crashes hard when the LLM ignores
   `tool_choice: :none`.** When the LLM hits the iteration cap, the
   runner sets `tools: nil, tool_choice: :none` for the final call
   (`llm_runner.ex:65-82`). If the model (e.g. qwen3.5-plus via
   model-studio's Anthropic protocol) emits tool calls anyway, the
   dispatch path tries to execute them with `ctx.tools = nil` and
   crashes with `Protocol.UndefinedError: Enumerable not implemented
   for Atom. Got value: nil`. The chat task dies; the user has to
   recover manually. Stacktrace:
   ```
   (nest 0.1.0) lib/nest/llm/tools.ex:82: Nest.LLM.Tools.execute_one/3
   (nest 0.1.0) lib/nest/agents/agent/tool_loop.ex:84
   (nest 0.1.0) lib/nest/tokens/budget_planner.ex:121
   (nest 0.1.0) lib/nest/agents/agent/tool_loop.ex:45
   ```

3. **Redundant `system_prompt` fields everywhere.** The agent's
   immutable system prompt lives in three places — `state.system_prompt`,
   `ctx.system_prompt`, and `request.system_prompt` — plus a separate
   system message in the messages list. This invites drift (the warning
   append in (1) was a symptom) and adds a special code path for
   "system content" that should just be a regular `{:system, _}` message.

## Design

- All system messages live in the messages array in order, with the
  immutable initial system at position 0 and any late reminders at
  later positions. The LLM client wire formats are the only place
  the "position 0 is special" convention is consumed.
- No `system_prompt` field on `Agent`, `RunContext`, or `RunRequest`.
  The system message at position 0 of the messages list is the single
  source of truth.
- Late system reminders (e.g. the budget warning) are regular
  `{:system, %System{...}}` messages injected into the messages list.
  They get broadcast to the UI and persisted in
  `state.chat_state.messages` via the same flow as any other message.
  No "ephemeral" flag, no special-casing.
- If a caller passes no system content, an empty `{:system, _}` is
  still inserted at position 0. The Anthropic client uses this to
  unconditionally extract a system message for the top-level
  `"system"` field without conditional logic.
- OpenAI client: maps every `{:system, _}` to `{"role": "system", ...}`
  at its position in the messages array (uses OpenAI's "late system
  message" feature for reminders).
- Anthropic client: extracts the FIRST `{:system, _}` for the top-level
  `"system"` field, maps the rest normally using
  `{"role": "system", ...}` (Anthropic's May 2026 `role: "system"`
  support).
- When the LLM ignores `tool_choice: :none` on the max-iterations
  final call, synthesize error tool results for each call, send them
  through the normal flow, and make ONE more LLM call with the errors
  in the message history and `tools: nil, tool_choice: :none`. A new
  `force_finalize: true` flag on `RunState` ensures this second-chance
  call force-finalizes (drops any further tool calls, takes the text)
  to break the potential infinite loop.

## Changes

### Production code

#### `lib/nest/agents/agent.ex`
- Remove `:system_prompt` from the Agent struct's `defstruct` and
  the `system_prompt: String.t() | nil` line from the `@type`.
- Update the moduledoc comment to note that the system prompt lives
  at position 0 of `state.chat_state.messages`.

#### `lib/nest/agents/agent/init.ex`
- `initial_messages_with_system/1`: collapse the empty-string clause
  into the main function. Always return a system message at position 0
  with `content: system_prompt || ""`. No more "no system message"
  branch.
- `build_state/2`: remove the `system_prompt: system_prompt` line from
  the Agent struct construction. The system prompt is now expressed
  solely through the messages list.
- `run_post_init/2`: replace the `if state.system_prompt do ... end`
  broadcast check with a `case state.chat_state.messages do ... end`
  that inspects position 0 directly. Empty system messages are not
  broadcast (would render as an empty chat bubble in the UI).

#### `lib/nest/agents/agent/llm_runner.ex`
- `RunContext` defstruct: remove `system_prompt: nil`. The system
  message lives in `ctx.messages`.
- `build_run_context/4`: drop the `system_prompt: state.system_prompt`
  line.
- `build_run_request/1`: drop the `reject_system_messages/1` filter
  and the `system_prompt: ctx.system_prompt` field. System messages
  stay in `ctx.messages`.
- `run_with_new_client_after_tool_calls/3`: delete the
  `system_prompt = case iteration_warning(next_state.max_iterations) ...`
  block. Replace with a call to `maybe_inject_budget_warning/3` (see
  below) that appends a regular system message to `updated_messages`
  when `next_state.max_iterations` is 1 or 2.
- `RunState` defstruct: add `force_finalize: false`. Used to break
  the second-chance loop in the max-iterations-with-ignored-
  tool_choice path.
- `handle_new_response/3`: rewrite as a `cond` with three branches:
  1. `state.force_finalize` — force-finalize (drops any tool calls,
     takes the text). Used for the second-chance call.
  2. `state.max_iterations <= 0 and RunResponse.has_tool_calls?(response)`
     — call `handle_max_iterations_with_tool_calls/3`.
  3. `RunResponse.has_tool_calls?(response)` — normal flow,
     `run_with_new_client_after_tool_calls/3`.
  4. else — `send_final_assistant/3`.
- New `handle_max_iterations_with_tool_calls/3`: log a warning,
  build synthetic error tool results via
  `build_synthetic_error_pair/3`, send them to the GenServer via
  `tool_calls_received` / `tool_results_received` tags, then make a
  second LLM call with `force_finalize: true`,
  `tools: nil, tool_choice: :none`, and the error tool results
  appended to the messages.
- New `build_synthetic_error_pair/3`: build a `tool_call_message`
  from the LLM's tool calls, a `tool_result_message` with
  `is_error: true` for each call (content: "Maximum tool iterations
  reached; cannot execute further tool calls. Please provide a final
  response to the user based on the conversation so far."), and
  return `{tool_call_message, tool_result_message, ctx.messages ++
  [tool_call_message, tool_result_message]}`.
- New `maybe_inject_budget_warning/3`: when `remaining` is 1 or 2,
  build a `{:system, %System{content: warning}}` reminder, send
  `{:system_reminder_received, reminder}` to the GenServer for
  broadcast + persist, and append the reminder to the messages list.

#### `lib/nest/agents/agent/handlers/llm_stream_handler.ex`
- New `handle({:system_reminder_received, reminder_message}, state)`
  and `defp system_reminder_received/2` handler. Appends the
  reminder to `state.chat_state.messages`, increments
  `next_message_index`, and broadcasts via `Broadcasts.message/2`.
  Same shape as `tool_results_received/2`.

#### `lib/nest/agents/agent/handlers.ex`
- Add `defp route_for({:system_reminder_received, _}), do:
  {:ok, LLMStreamHandler}`.

#### `lib/nest/llm/run_request.ex`
- Remove `system_prompt: nil` from the `defstruct` and the
  `system_prompt: String.t() | nil` line from the `@type`.

#### `lib/nest/llm/client.ex`
- Remove `reject_system_messages/1` (no longer called; the system
  message stays in the messages list).

#### `lib/nest/llm/openai_client.ex`
- `format_request_payload/2`: drop the `request.system_prompt` arg
  from `build_wire_messages/1`. `"messages" =>
  build_wire_messages(request.messages)`.
- `build_wire_messages/1`: simplify to `Enum.flat_map(messages,
  &message_to_wire/1)`.
- Delete `prepend_system_message/2` (the system message is already
  at position 0 of `request.messages`).
- The existing `message_to_wire({:system, _})` clause handles the
  system message at position 0 and any late system reminders at
  their positions.

#### `lib/nest/llm/anthropic_client.ex`
- `format_request_payload/2`: extract the first system message
  inline:
  ```elixir
  {initial_system, conversation_messages} =
    case request.messages do
      [{:system, %System{content: content}} | rest] -> {content, rest}
      other -> {nil, other}
    end
  ```
  Use `initial_system` for the top-level `"system"` field via
  `maybe_put("system", initial_system)`. `maybe_put/3` correctly
  omits the field when `initial_system` is nil. Map
  `conversation_messages` for the wire `"messages"` array.
- Add `message_to_wire({:system, _})` clause mapping late system
  reminders to `{"role": "system", ...}` (uses May 2026
  Anthropic `role: "system"` support in messages array).

#### `lib/nest/llm/tools.ex`
- Add defensive nil/non-list guard to `execute_one/3`,
  `execute/3`, and `default_max_result_tokens/2`. Returns
  `{:error, "Tool list unavailable; cannot execute `<name>`"}`
  when `tool_defs` is not a list. Protects against any path that
  passes nil or a non-list (e.g. the `ctx.tools = nil` that fired
  in the max-iterations crash).

### Tests

#### `test/nest/agents/agent_tools_test.exs`
- New test: budget reminder is sent as a regular system message
  in the messages array at the position after the latest tool
  result. Assert: the reminder is broadcast as `chat:message` with
  `role: "system"`. Assert: the reminder is persisted in
  `state.chat_state.messages`. Assert: the LLM call's `messages`
  list includes the reminder at the right position. Regression
  guard for the system-prompt-mutation bug.
- New test: max-iterations with the LLM ignoring `tool_choice:
  :none` synthesizes error tool results and gives the LLM one more
  chance. Assert: no `chat:error`; second-chance text is the
  final answer; the synthetic tool result has `is_error: true`
  and the "Maximum tool iterations reached" content.
- New test: force-finalizes the second-chance response if the LLM
  still emits tool calls. Assert: no `chat:error`; the second-
  chance text is the final answer; the second-chance tool calls
  are dropped; agent goes idle.

#### `test/nest/llm/openai_client_test.exs`
- New test: `request.messages` with system at position 0 maps to
  first wire entry with `role: "system"`. Late system reminder
  maps to a later entry with `role: "system"`.

#### `test/nest/llm/anthropic_client_test.exs`
- New test: `request.messages` with system at position 0 — top-level
  `"system"` field gets the first content, late reminder stays in
  the messages array as `role: "system"`.
- Sub-case: `request.messages` without system at position 0 —
  top-level `"system"` field is omitted, system message goes into
  the messages array as `role: "system"`.

#### `test/nest/llm/tools_test.exs`
- New test: `execute_one/3` returns `{:error, "Tool list
  unavailable"}` when `tool_defs` is `nil`, `%{}`, or a non-list
  string.

#### `test/nest/agents/agent_init_test.exs` (or equivalent)
- New tests for `initial_messages_with_system/1`:
  - With `nil`: returns `[{:system, %System{content: ""}}]`
  - With `""`: returns `[{:system, %System{content: ""}}]`
  - With a real prompt: returns `[{:system, %System{content: prompt}}]`
- New test for `run_post_init/2`:
  - When the initial system message has non-empty content, it's
    broadcast
  - When the initial system message has empty content, it's not
    broadcast

## Tradeoffs

- Late system reminders persist in `state.chat_state.messages`. Future
  turns see the stale "1 round left" reminder in the history. We
  accept this as the cost of transparency (over hiding the reminder).
  In practice, most turns don't approach max iterations, so the
  reminder is rare. When present, the LLM can act on or ignore it
  — it's stale but harmless.
- The max-iterations-with-ignored-tool_choice path adds one extra
  LLM call (~1-2s latency) when the LLM doesn't cooperate. The
  alternative is dropping the tool calls silently, which loses the
  LLM's text response.

## Out of scope

- The chat UI rendering of `role: "system"` reminder messages
  (these were previously treated as ephemeral). The reminder now
  follows the same flow as any other message; the chat UI already
  handles system-role messages.
- Filtering the stale reminder from future turns' LLM calls. A
  follow-up could add a marker, but for now the user accepts
  persistence for transparency.
- Removing the `state.vocation` field (technically redundant with
  `state.vocation_id`). Out of scope.
- Why qwen3.5-plus (or other providers) don't respect
  `tool_choice: :none`. Provider quirk, can't fix from our side.
