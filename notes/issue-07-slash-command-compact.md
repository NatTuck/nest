# Issue #7 — Time for slash commands (`/compact`) (plan)

> Produced by a planning minion, read-only. Pending team-lead review.

## Goal
Let the user type `/compact` in the chat composer to trigger the existing compaction path for the current agent, without persisting a user message, and in a way that extends to more commands.

## Current behavior & root cause (evidence)

There is **no slash-command handling anywhere**; every composer submission becomes a chat message, and compaction has no "compact now" entry point.

- The composer sends raw text: `ChatInput` calls `onSend()` on Ctrl/Cmd+Enter (`assets/js/components/ChatInput.jsx:117-126`) and on form submit (`assets/js/components/ChatInput.jsx:266-274`); `ChatComposer` just forwards to `ChatInput` (`assets/js/components/ChatComposer.jsx:55`); `ChatPage.handleSendMessage` trims and calls `sendMessage` (`assets/js/pages/ChatPage.jsx:313-329`).
- `sendMessage` **optimistically appends a user message** then pushes `chat:message` (`assets/js/channels/agent.js:455-473`).
- The server `handle_in("chat:message", ...)` calls `Agents.chat/4` (`lib/nest_web/channels/agent_channel.ex:307-336`), which casts `{:chat, content, mode}` to the Agent (`lib/nest/agents.ex:264`, `lib/nest/agents/agent.ex:315`).
- Compaction can currently only be triggered three ways, none of them "user asks from idle":
  1. auto-preflight when a projected send doesn't fit — `start_chat` → `:needs_compaction` → `Compaction.stage(...)` (`lib/nest/agents/agent/machine/transitions.ex:386-388`);
  2. the LLM's `context-compact` tool (`lib/nest/tools.ex:248-274`, intercepted in `lib/nest/agents/agent/machine/response.ex:191-235`);
  3. retry from the `:compaction_failed` blocked phase — `:retry_compaction` → `Compaction.stage(...)` (`lib/nest/agents/agent/machine/transitions.ex:79-87`), reached via `chat:retry-compaction` (`agent_channel.ex:390`, `lib/nest/agents/agent/callbacks.ex:166`).
- The machine's idle phase has **no** transition that stages a compaction directly (see the idle clauses, `lib/nest/agents/agent/machine/transitions.ex:197-250`), and `:compact_request` is not in the declared event vocabulary (`lib/nest/agents/agent/machine.ex:60-88`). `Machine.step/2` quarantines undeclared tags (`machine.ex:236-242`), so a new event is required.

So what remains is exactly: client parsing/autocomplete, a wire entry point, and a new idle→compaction machine trigger.

## Design decision: a new push event, not a chat message

Send `/compact` as a **dedicated channel push (`chat:compact`)**, not as a `chat:message`.

Rationale:
- A command is control-plane, not conversation content. Routing it through `chat:message` would either persist a bogus `/compact` user bubble that has no assistant reply and then gets summarized away, or force the server to special-case and drop it after the client already optimistically appended it (`agent.js:463`).
- UI transparency is preserved: the command is **not** sent to the LLM, so it need not appear as a message. The user gets feedback from the existing `chat:status: compacting` broadcast (header shows "Compacting conversation…" — `assets/js/utils/chatErrors.js:35-38`) and the existing `chat:compaction` marker divider.
- It mirrors the established pattern for non-message actions (`chat:stop`, `chat:retry-compaction`, `chat:loop-detected-ok`).

The command still reuses the **exact** existing compaction path: a new `:compact_request` machine event from `:idle` calls the same `Compaction.stage/3` used by auto-compaction and retry (`lib/nest/agents/agent/machine/compaction.ex:23`). Compaction internals are untouched.

Extensibility: commands are declared once in a client registry (`{name, description}`) and wired to an action in one dispatch map. Adding `/clear` (client-only) is a registry entry + a local function; adding another server command is a registry entry + a dispatch entry + a channel `handle_in` (+ Agent/Agents API if it touches machine state). The parser and autocomplete are command-agnostic.

## Ordered tasks

### Server

1. **Declare the event** — `lib/nest/agents/agent/machine.ex:60-88`
   Add `:compact_request` to `@events`. Acceptance: `Machine.events()` includes it; no other vocabulary change.

2. **Add the idle transition** — `lib/nest/agents/agent/machine/transitions.ex` (idle section, near line 197)
   ```elixir
   def do_step(%{phase: :idle} = m, :compact_request), do: Compaction.stage(m, nil, nil)
   ```
   Leave non-idle phases to the existing catch-all `{:ignore, :not_applicable, m}` (`transitions.ex:369`). Acceptance: from `:idle` the machine enters `kind: :compaction, phase: :generating` with `entry: {:compaction, staged, nil}` and emits `:iterate`; from any other phase it is ignored; `Machine.validate!/1` holds (the coverage tests already assert this for every phase/event pair).

3. **Agent API** — `lib/nest/agents/agent.ex` (near `retry_compaction/1`, line 357)
   ```elixir
   @spec compact(pid()) :: :ok | {:error, {:not_idle, atom()}}
   def compact(pid), do: GenServer.call(pid, :compact, :infinity)
   ```
   Acceptance: synchronous; consistent with `retry_compaction/1`/`stop_chat/2` (call over cast, per SMELLS.md).

4. **Agent handler** — `lib/nest/agents/agent/callbacks.ex` (near `handle_call(:retry_compaction, ...)`, line 166)
   ```elixir
   def handle_call(:compact, _from, state) do
     case Machine.status_for(state.live.machine) do
       :idle ->
         {:ok, state} = Turn.settle(state, :compact_request)
         {:reply, :ok, state}
       status ->
         {:reply, {:error, {:not_idle, status}}, state}
     end
   end
   ```
   Acceptance: idle starts compaction and returns `:ok`; any other status returns `{:error, {:not_idle, status}}` without side effects. This is the single authority (no redundant channel-side status check).

5. **Agents API** — `lib/nest/agents.ex` (near `retry_compaction/2`, line 317)
   ```elixir
   @spec compact(integer(), String.t()) ::
           :ok | {:error, :not_found | {:not_idle, atom()}}
   def compact(space_id, name) do
     case Supervisor.get_agent(space_id, name) do
       {:ok, pid} -> Agent.compact(pid)
       {:error, _} = err -> err
     end
   end
   ```

6. **Channel handler** — `lib/nest_web/channels/agent_channel.ex` (near `handle_in("chat:retry-compaction", ...)`, line 390)
   ```elixir
   def handle_in("chat:compact", _payload, socket) do
     case Agents.compact(socket.assigns.space_id, socket.assigns.name) do
       :ok -> {:reply, {:ok, %{}}, socket}
       {:error, {:not_idle, status}} ->
         {:reply, {:error, %{"reason" => "agent_status_#{status}"}}, socket}
       {:error, :not_found} ->
         {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
     end
   end
   ```
   Acceptance: idle → `{:ok, %{}}`; streaming/executing/compacting/frozen → `{:error, %{"reason" => "agent_status_<status>"}}`.

### Client

7. **Channel function** — `assets/js/channels/agent.js` (near `retryCompaction`, line 499)
   Add `export function compactAgent(agentId, onError)` that pushes `chat:compact` and reports push errors via `onError`. It must **not** call `store.addUserMessage` and must **not** set `waitingForResponse` (unlike `sendMessage`, lines 461-472). Acceptance: same not-connected guard as `retryCompaction`.

8. **Command registry + parser** — new `assets/js/utils/slashCommands.js` (pure, no channel imports)
   - `SLASH_COMMANDS = [{ name: "compact", description: "Compact the conversation to free up context." }]`
   - `parseSlashCommand(text)` → `{ name, args }` only when the trimmed text's first token exactly matches a registered name (e.g. `/compact`); returns `null` for empty, bare `/`, or unknown commands.
   - `commandSuggestions(text)` → registered commands whose name is a prefix of the current partial token, only while the text is `/<partial>` with no whitespace.
   Acceptance: unit-testable in isolation.

9. **Autocomplete UI** — `assets/js/components/ChatInput.jsx`
   Accept a `commands` prop. When `commandSuggestions(value)` is non-empty and the input is interactive, render an absolutely-positioned suggestion menu (role `listbox`/`option`) above the textarea. While the menu is open: ArrowUp/ArrowDown move the highlight, Enter or Tab accepts the highlighted command by calling `onChange("/" + name)`, Escape closes; when closed, existing Enter-inserts-newline / Ctrl+Enter-sends behavior is unchanged (`handleKeyDown`, lines 117-190). Selecting a suggestion must not send. Acceptance: keyboard-only selection works; the menu is absent for non-`/` input.

10. **Composer passthrough** — `assets/js/components/ChatComposer.jsx:55`
    Forward a `commands` prop to `ChatInput`.

11. **Dispatch in the page** — `assets/js/pages/ChatPage.jsx`
    - Add a module-scope map `{ compact: (agentId, onError) => compactAgent(agentId, onError) }`.
    - In `handleSendMessage` (line 313), before the existing `sendMessage` path: `const parsed = parseSlashCommand(inputValue);` if `parsed` and the map has an action, clear the input, reset `sendError`, invoke the action with `(name, onError → setSendError)`, and return. Unknown `/foo` (parser returns `null`) falls through to a normal message (no silent drop).
    - Pass `commands={SLASH_COMMANDS}` to `ChatComposer` (line 565).

### Docs

12. **Protocol spec** — `notes/spec/agent-channel-protocol.md`
    Add a `chat:compact` client→server subsection (payload `{}`; responses as in task 6) after `chat:retry-compaction` (line 165).

## Tests

- **`test/nest/agents/agent/machine_test.exs`**
  - Add `defp sample_event(:compact_request), do: :compact_request` in the helper block (near line 436). Required or the transition-coverage test (lines 50-83) and property test (lines 256-282) crash.
  - Add one behavior test: from `state_at(:idle)`, `:compact_request` yields `:iterate`, `kind: :compaction`, `phase: :generating`, `entry: {:compaction, staged, nil}`; from `state_at(:generating)` it is `{:ignore, :not_applicable, _}`.
- **`test/nest/agents/agent/guard_test.exs`** — add `sample_event(:compact_request)` (line ~181) for its "every declared event is handled" test (lines 51-56).
- **`test/nest/agents/agent/machine_structure_test.exs`** — add `sample_event(:compact_request)` (line ~253) for its "step/2 handles every declared Machine event" test (lines 159-165).
- **`test/nest/agents_test.exs`** — add `describe "compact/2"`:
  - `{:error, :not_found}` for a nonexistent agent.
  - `{:error, {:not_idle, :streaming}}` when the agent is fabricated as streaming (`:sys.replace_state` + `Machine.status_to_machine/2`), asserting no compaction starts. (Covers the callback guard without a live compaction.)
- **`test/nest_web/channels/agent_channel_compaction_test.exs`** (or `agent_channel_chat_test.exs`) — add `describe "handle_in(chat:compact)"`:
  - idle agent: `push(socket, "chat:compact", %{})` → `assert_reply :ok, %{}`; `assert_push "chat:status", %{status: "compacting"}` then `%{status: "idle"}` (MockClient's random-text fallback completes the compactor, exactly as the existing `chat:retry-compaction` test at `agent_channel_chat_test.exs:575-595`). This covers channel → `Agents.compact` → `Agent.compact` → callback → `:compact_request` → `Compaction.stage` end to end.
  - busy agent: fabricate `:compacting` (as at `agent_channel_chat_test.exs:437-458`) → `assert_reply :error, %{"reason" => "agent_status_compacting"}`.
- **`assets/js/utils/slashCommands.test.js`** (new) — `parseSlashCommand` matches `/compact` (with surrounding whitespace), returns `null` for `""`, `/`, `/unknown`, `hello`, and `/compactx`; `commandSuggestions` returns `compact` for `/`, `/c`, `/com` and `[]` for `/compact ` and `hello`.
- **`assets/js/components/ChatInput.test.jsx`** — with `commands` set: typing `/` shows the menu; ArrowDown+Enter selects and calls `onChange("/compact")` without calling `onSend`; Enter with no menu still inserts a newline (existing test); menu hidden for non-command text.
- **`assets/js/channels.test.js`** — `describe("compactAgent")`: no-op/`onError` when not connected; pushes `chat:compact` (use `captureNextPush`), does **not** add a user message or set `waitingForResponse`; surfaces push errors via `onError` (mirror `retryCompaction`, lines 3488-3565).
- **`assets/js/pages/ChatPage.test.jsx`** — add `compactAgent` to the `vi.mock("../channels")` factory (line 61) and assert that sending `/compact` calls `compactAgent(name, …)` and **not** `sendMessage`, and clears the input; that sending `/unknown` calls `sendMessage`; and that a `compactAgent` `onError` surfaces in `SendErrorBanner`.

## Edge cases & risks

- **New-event churn**: adding to `@events` requires `sample_event/1` in three test files; miss one and the suite won't compile. Listed above.
- **Loop breaker**: `Compaction.stage/3` increments `loop_count`, which only resets when a user/assistant/tool message is appended (`lib/nest/agents/agent/message_appender.ex:84-96,263`). Three consecutive `/compact`s with no intervening turn will trip `:compaction_loop_detected`. This may be acceptable (it *is* a loop) but the message is automatic-loop wording; decide whether a manual request should reset `loop_count` (see open questions).
- **Double-fire**: while `:compacting`, the server rejects `/compact` (`agent_status_compacting`). Note the composer does **not** currently disable during `:compacting` (`ChatPage.jsx` `isAgentBusy` excludes it; `frozen` excludes it), so the user can still type/send and get an error — a pre-existing gap, only relevant if you want `/compact` to be un-clickable mid-compaction.
- **Unknown command**: default is to send `/foo` as an ordinary message (no silent drop). If a visible "unknown command" error is preferred, `parseSlashCommand` should return the name and ChatPage should show `sendError` instead of falling through.
- **No persisted/echoed command**: by design no user bubble is created; the compaction divider and `compacting` status are the feedback. Confirm this satisfies the project's transparency rule (the command never reaches the LLM).
- **`focus` arg**: the LLM `context-compact` tool accepts a `focus` string (`lib/nest/tools.ex:255-266`); `/compact` here deliberately takes none. Passing `/compact <focus>` through would require an arg on `chat:compact` and `Compaction.stage` — explicitly out of scope.
- **Race safety**: because the Agent handler is the authority, there is no TOCTOU window (unlike a channel-side status check).

## Verification (do not run now)

1. `mix precommit` — read the **full** output; it must be 100% clean (format, credo, biome, Elixir + JS tests, coverage). No warnings, no test log prints.
2. If iterating: `cd assets && pnpm vitest run` (or `mix assets.test`) and `mix assets.check`; Elixir: `mix test` (suite must stay under 5s).
3. Confirm new coverage of the new Elixir/JS lines (the new machine event, callback, channel clause, `compactAgent`, `slashCommands`, ChatInput menu).

## Open questions / decisions for the user

1. **Manual compaction vs the loop breaker**: should a user-initiated `/compact` reset `loop_count` (so 3 manual compactions don't trip `:compaction_loop_detected`), or is tripping acceptable?
2. **Unknown `/foo`**: send as a normal message (proposed) or show an inline "unknown command" error?
3. **Autocomplete acceptance key**: Enter/Tab when the menu is open (proposed) vs click-only, given Enter normally inserts a newline here.
4. **Command echo**: is the compaction divider + status label enough feedback, or should the UI show a transient "Compacting…" affordance tied to the command?
5. **Busy-state composer**: include `:compacting` in the composer's disabled/busy logic (fixes a pre-existing gap and prevents double-fire), or leave as-is?
6. **Dependencies on other issues**: none required. The `context-compact` tool and the preflight/retry compaction paths already exist; this plan adds only the user-initiated trigger. If a separate issue changes the compaction trigger vocabulary, tasks 1-4 should be reconciled with it.
