# Redundancy & Code Smell Cleanups

## SMELLS.md #1: Redundant Code

### 1. Extract `maybe_put/3` to a shared helper (4 duplicates)

Affected files — identical `defp maybe_put(map, _key, nil), do: map; defp maybe_put(map, key, value), do: Map.put(map, key, value)`:
- `lib/nest/llm/openai_client.ex:465-466`
- `lib/nest/llm/anthropic_client.ex:457-458`
- `lib/nest/llm/mock_client.ex:382-383`
- `lib/nest/agents/persisted_message.ex:229-230`

**Fix:** Add `maybe_put/3` to an existing shared module (e.g., `Nest.Messages.Message` or a new `Nest.Utils`), replace all 4 private definitions with imports/aliases. If the function is only used by LLM clients + persisted_message, putting it on `Nest.LLM.Client` is a reasonable home.

### 2. Eliminate duplicated `load_vocation/1`

Affected files:
- `lib/nest/persistence.ex:77-78` — `def load_vocation(nil), do: nil; def load_vocation(vocation_id), do: Vocations.get_vocation(vocation_id)`
- `lib/nest/agents/agent/init.ex:97-98` — identical copy

**Fix:** Keep one canonical definition. Check all callers — if `Persistence.load_vocation/1` is the one used externally (it's a public context function), remove the `Init.load_vocation/1` copy and have `init.ex` call `Persistence.load_vocation/1` instead. Alternatively, move it to `Nest.Vocations` (since `Vocations.get_vocation/1` already exists, `load_vocation` is just the nil-safe wrapper) and have both callers use `Vocations` directly.

### 3. Extract shared client helper functions from LLM client modules

Affected files:
- `lib/nest/llm/openai_client.ex`
- `lib/nest/llm/anthropic_client.ex`
- `lib/nest/llm/mock_client.ex`

Duplicated helpers to extract into `Nest.LLM.Client` (or a new `Nest.LLM.Client.Helpers`):
- `normalize_endpoint/2` — identical in openai_client and anthropic_client
- `strip_api_version_if_needed/2` — identical in openai_client and anthropic_client
- `text_from_parts/1` — identical in openai_client and mock_client (+ `AnthropicClient.system_text_from_parts` is the same logic)
- `tool_calls_from_parts/1` — identical in openai_client and mock_client
- `normalize_tool_choice/1` — same dispatch structure; extract common dispatch, keep only the provider-specific conversion inline

### 4. Extract `text_from_parts` to a shared location (5 call sites)

The pipeline `Enum.filter(&match?(%Part.Text{}, &1)) |> Enum.map_join("", & &1.text)` appears in:
- `lib/nest/llm/openai_client.ex:135-136`
- `lib/nest/llm/mock_client.ex:345-346`
- `lib/nest/llm/anthropic_client.ex:180-181` (as `system_text_from_parts/1`)
- `lib/nest/agents/agent/introspection_handler.ex:140-141`
- `lib/nest/agents/agent/handlers/chat_turn_handler.ex:142-143` (as `last_assistant_text/1`)

**Fix:** Add `Nest.Messages.Part.text_from_parts/1` (and possibly `thinking_from_parts/1`) and replace all inline implementations. The client modules can alias `Nest.Messages.Part`.

### 5. Remove duplicate `pending_api_logs/2` private helper

- `lib/nest/agents/agent/handlers/chat_turn_handler.ex:371-373`
- `lib/nest/agents/agent/handlers/llm_stream_handler.ex:320-322`

**Fix:** Both are `defp pending_api_logs(state, idx), do: Nest.Agents.Agent.__pending_api_logs__(state, idx)`. Since the defdelegate on `Agent` already exists for circular-dep reasons, inline the `__pending_api_logs__` call at the 3 call sites in chat_turn_handler (or have one handler re-use the other's definition — though that's coupling). Simplest: move to a shared inner module or just inline the call.

### 6. Extract `DateTime.utc_now() |> DateTime.truncate(:second)` to a helper

5 occurrences:
- `lib/nest/persistence.ex:149, 359`
- `lib/nest/persistence/compaction_marker.ex:55`
- `scripts/compact_agent_history.exs:318, 321`

**Fix:** Add `Nest.Persistence.now/0` (or `Nest.Persistence.utc_now_truncated/0`) and use it everywhere.

### 7. JS: Extract duplicated `ChevronDown` component

- `assets/js/components/TruncatedResult.jsx:36`
- `assets/js/components/CompactionMarker.jsx:47`

**Fix:** Create `assets/js/components/ChevronDown.jsx` and import from both.

### 8. JS: Extract duplicated `formatTimestamp` function

- `assets/js/components/CollapsedHistory.jsx:63`
- `assets/js/components/CompactionMarker.jsx:165`

**Fix:** Create `assets/js/utils/formatTimestamp.js` and import from both.

### 9. JS: Extract `<StreamingDots />` component

Inline bouncing-dots animation duplicated in:
- `assets/js/components/ThinkingBlock.jsx:60-81`
- `assets/js/pages/ChatPage.jsx:549-600`

**Fix:** Create `<StreamingDots />` component and replace both inline usages.

### 10. JS: Extract markdown container CSS to a constant

Identical class string on `MessageContent.jsx:100` and `:111`.

**Fix:** Define `const MARKDOWN_CONTAINER_CLASS = "space-y-2 [&_pre]:whitespace-pre-wrap ..."` and reference it in both places.

### 11. JS: Reuse `textFromParts`/`thinkingFromParts` in `formatMessage.js`

`formatMessage.js:47-57` reimplements parts extraction that already exists in `messageText.js`.

**Fix:** Import and use the existing `textFromParts`/`thinkingFromParts` from `messageText.js`.

---

## SMELLS.md #2: Useless Precondition Checking

### 12. Remove pre-check query in `Vocations.delete_vocation/1`

File: `lib/nest/vocations.ex:105-120`

Current code does `agents_using_vocation?` (an O(n) EXISTS query) then `try Repo.delete/1 rescue Ecto.ConstraintError` — and both branches return the same `{:error, :agents_using_vocation}`.

**Fix:** Remove the `if agents_using_vocation?` pre-check and the `else` branch. Just attempt `Repo.delete/1` and catch the constraint error. Cuts a pointless DB round-trip.

### 13. Replace read-then-write with upsert in `Vocations.upsert_vocation/1`

File: `lib/nest/vocations.ex:139-155`

Current code does `Repo.get_by(name:)` then branches to insert or update. Comment acknowledges race window. If there's a unique index on `name`, use `on_conflict`. If not, add the index then use `on_conflict`.

**Fix:** Use `Repo.insert(on_conflict: :replace_all_except_primary_key)` or `Ecto.Repo.insert(..., on_conflict: [set: ...])` with a unique index on `name`.

### 14. Remove `Process.alive?` TOCTOU races in `Agents.get_info/1` and `get_messages/1`

File: `lib/nest/agents.ex:81, 187`

Both do `if Process.alive?(pid) -> GenServer.call`, which has a time-of-check-time-of-use race. Meanwhile `get_agent/1`, `chat/3`, `stop_chat/3`, etc. in the same module skip this check.

**Fix:** Remove the `Process.alive?` guard. `GenServer.call` on a dead process will return `{:error, :noproc}` which can be caught or propagated naturally.

### 15. Simplify `Supervisor.stop_agent/1` — remove empty-list branch

File: `lib/nest/agents/supervisor.ex:342-354`

Both branches call `stop_one(name)`. The `if children == []` only skips a `for` over an empty list, which is already a no-op. `cascade_children_only/1` in the same file doesn't bother with this check.

**Fix:** Remove the `if` branch and just do:
```elixir
for child_name <- ChildRegistry.children_of(name), do: _ = stop_agent(child_name)
stop_one(name)
```

### 16. Remove redundant `Process.alive?` in `SurgicalReloader.walk_tree/2`

File: `lib/nest_web/surgical_reloader.ex:244-268`

The `rescue _ -> acc` block already handles dead-supervisor exceptions. The `Process.alive?` check is both racy and redundant.

**Fix:** Remove the `if Process.alive?` guard. The rescue block already covers this case.

---

## SMELLS.md #3: Useless Delegation or Abstraction

### 17. Collapse `CompactionHandler` into `ResultHandler`

File: `lib/nest/agents/agent/handlers/compaction_handler.ex:37-55`

All 5 `handle/2` clauses are `{:noreply, ResultHandler.something(args)}`. The module adds zero value beyond `{:noreply, ...}` wrapping.

**Fix:** Have the top-level `Handlers` dispatcher call `ResultHandler` directly and wrap the result in `{:noreply, ...}`. Delete `CompactionHandler` module. Or, keep the file but move the `handle/2` clauses to `ResultHandler` and have `Handlers` dispatch there.

### 18. Remove `Agents.list_agents/0` passthrough

File: `lib/nest/agents.ex:152-154`

Body is `Supervisor.list_agents()`. Callers can call `Supervisor.list_agents()` directly, or the `Supervisor` function can be moved to `Agents` (or `Registry`) since `Supervisor.list_agents/0` itself is just `Registry.list()`.

**Fix:** Check all callers of `Agents.list_agents/0`. Either:
- Delete `Agents.list_agents/0` and have callers go through `Supervisor` or `Registry`
- Or delete `Supervisor.list_agents/0` and move the `Registry.list()` call to `Agents.list_agents/0` (since the Agents context is the public API, keeping the context function but cutting the 2-hop delegation is cleaner)

### 19. Remove `Agents.delete_agent/1` passthrough

File: `lib/nest/agents.ex:328-330`

Body is `Supervisor.stop_agent(name)`. Same analysis as #18.

**Fix:** Either inline at call sites or remove the `Supervisor` copy and keep the `Agents` one (since it's the public API surface).

### 20. Remove `Init.attach_rebuilt_api_logs/3` passthrough

File: `lib/nest/agents/agent/init.ex:172-174`

Body is `Restore.attach_rebuilt_api_logs(state, preloaded, last_compaction_index)`. Only called from `agent.ex:286-290`.

**Fix:** Have the caller in `agent.ex` call `Restore.attach_rebuilt_api_logs/3` directly. Delete the wrapper function.

### 21. Inline `SubAgent.agents_chat/2` private wrapper

File: `lib/nest/agents/agent/sub_agent.ex:119-120`

`defp agents_chat(name, content), do: Nest.Agents.chat(name, content)`. Called once.

**Fix:** Call `Nest.Agents.chat/2` directly at the call site on line 64.

### 22. Consider removing `BatchSizer` defdelegates to `CapCalculator`

File: `lib/nest/agents/agent/batch_sizer.ex:144, 150`

`defdelegate usable_remaining(ctx), to: CapCalculator` and `defdelegate effective_max_result_tokens(tool_call, usable), to: CapCalculator`. These exported from `BatchSizer` for callers' convenience; the logic lives in `CapCalculator`.

**Fix:** Check all external callers of `BatchSizer.usable_remaining/1` and `BatchSizer.effective_max_result_tokens/2`. If callers already import `BatchSizer` for other reasons, keeping the convenience exports is fine. If not, have them call `CapCalculator` directly. Low priority, but the defdelegates are a sign that `CapCalculator` was extracted and the old API surface was preserved unnecessarily.

---

## JS Dead Code

### 23. Remove dead `NestLanding` component

File: `assets/js/components/NestLanding.jsx` (105 lines)

Only imported by its own test file. Never used in production (`App.jsx` routes don't reference it).

**Fix:** Delete `NestLanding.jsx` and `NestLanding.test.jsx`.

### 24. Remove dead `graphemeFirst` export

File: `assets/js/utils/grapheme.js:58`

Exported but never imported by any production file — only used in `grapheme.test.js`.

**Fix:** Remove the `graphemeFirst` function and its tests, or mark it `@deprecated` if there's a backward-compatibility reason to keep it.

---

## JS Deduplication (Additional)

### 25. Consolidate parts-extraction helpers between ChatPage and CollapsedHistory

Both `ChatPage.jsx` and `CollapsedHistory.jsx` define very similar `thinkingFor`, `textPartsFor`, `toolCallsFromParts`, `toolResultsFromParts` functions.

**Fix:** Extract these into a shared file (e.g., extend `assets/js/utils/messageText.js` with them) and import from both components.

---

## Order of Execution

1. **JS dead code first** — pure deletions, no risk (#23, #24)
2. **JS duplication extractions** — new small files/components, low risk (#7, #8, #9, #10, #11, #25)
3. **Extract `maybe_put/3`** — 4 identical copies, clear home, low risk (#1)
4. **Extract `text_from_parts`** — clear home on `Part` module, low risk (#4)
5. **Extract other shared client helpers** — `normalize_endpoint`, `strip_api_version_if_needed`, etc. (#3)
6. **Extract `DateTime` helper** — trivial, low risk (#6)
7. **Remove `Vocations.delete_vocation` pre-check** — small behavior change, verify tests (#12)
8. **Remove `Process.alive?` TOCTOU races** — small behavior change (#14, #16)
9. **Simplify `stop_agent` empty-list branch** — trivial (#15)
10. **Collapse `CompactionHandler`** — rename/move, verify tests (#17)
11. **Remove useless delegation functions** — (#18, #19, #20, #21)
12. **Vocations upsert** — requires DB migration (unique index), higher risk (#13)
13. **BatchSizer defdelegates** — low priority, last (#22)
