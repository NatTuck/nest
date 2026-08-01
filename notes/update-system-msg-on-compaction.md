# Regenerate system prompt on compaction

## Implementation Status

This design has been **implemented and superseded** by a simpler structural
fix in the post-compaction message sequence. The fresh system message is
re-rendered at compaction time via
`SystemPrompt.compose_vocation_config/4` (which re-reads AGENTS.md from disk
via `agents_md_section/1` and the vocation from the DB via
`Vocations.get_vocation/1`); the canonical `MessageAppender.append_one/2`
path assigns the index and persists the row. The post-compaction sequence
is now `[system_fresh, summary_user, ...carried_messages]`.

Sections 1-5 (schema changes + `delete_vocation/1` guard) remain valid
future-work notes; sections 6 and 7 (the `regenerate_for_compaction/2`
helper design) are obsolete — replaced by the canonical-message-append
path (see `notes/unify-message-sequence.md`).

## Architectural Notes (current implementation)

The architectural fix is that every entry added to
`(state.chat_state.history ++ state.chat_state.messages)` flows through
the canonical `MessageAppender` path:

  - New active messages → `MessageAppender.append_one/2` →
    `AgentPersistence.append_message/3` → `Persistence.insert_message/2`.
    Each gets stamped from `next_message_index`, persisted, broadcast
    as `chat:message`.
  - The compaction marker → `MessageAppender.append_history_one/2` (a
    history-variant sibling of `append_one/2`). Same stamp + persist,
    but writes to `state.chat_state.history` and skips the
    `chat:message` broadcast (the `chat:compaction` event carries
    the marker separately).
  - Pre-swap messages → moved to `history` in-memory only (their DB
    rows already exist at their pre-swap indices from earlier
    canonical appends).

`Persistence.insert_message/2` is the single insert primitive. It
dispatches on tuple shape: regular tuples (`{:system, _}`,
`{:user, _}`, `{:assistant, _}`, `{:tool, _}`) take the regular
`PersistedMessage.from_runtime/2` path; `{:compaction, %Compaction{}}`
takes the `CompactionMarker.record/5` path (atomic INSERT row + UPDATE
`agents.last_compaction_index` in one transaction).

This makes the invariant **structural**: there's no code path that
adds to `state.chat_state.messages` or `state.chat_state.history`
without also persisting a row at the assigned index. A future
refactor that adds a bypass would need to add new clauses to
`MessageAppender` and `Persistence.insert_message/2`, which is
obviously different from the existing code.

## Constraints

- **`vocation_id` is non-nil on every agent.** Schema enforces
  `agents.vocation_id NOT NULL` with `ON DELETE RESTRICT`. Runtime code
  uses `Map.fetch!/2` so a missing field raises immediately.
- **Vocations are not deletable while agents reference them.** The FK
  constraint rejects `DELETE`; `Vocations.delete_vocation/1` does a
  pre-check and returns `{:error, :agents_using_vocation}`.
- **Vocation DB-missing is transient.** If `Vocations.get_vocation/1`
  returns nil or raises (network blip, replication lag, etc.), the
  regeneration uses the cached `state.vocation` and logs a warning. The
  next compaction retries.
- **Compactor's `new_messages` always starts with `{:system, _}`.** This
  is structurally guaranteed by `Nest.Tokens.Compactor.compact/3` —
  the `:too_short` branch returns the input unchanged (which always
  starts with system), and the other branches explicitly prepend the
  original system. The handler pattern-matches this invariant; violation
  raises (an alarm, not a silent degradation).
- **No message is lost or changed.** Every message in the post-compaction
  sequence (fresh system, encoded summary, compactor's user/assistant/tool
  output) is persisted in the `messages` table at the index
  `Lifecycle.apply/2` assigns it.

## No new migration

Edit `priv/repo/migrations/20260629033544_create_agent_persistence.exs:61` in
place:

```diff
-      add :vocation_id, references(:vocations, on_delete: :nilify_all)
+      add :vocation_id, references(:vocations, on_delete: :restrict), null: false
```

Apply with `mix ecto.reset`. No backfill, no down-migration concerns, no
migration ordering problem.

## Changes

### 1. Schema (one-line edit)

**`priv/repo/migrations/20260629033544_create_agent_persistence.exs:61`**

```diff
-      add :vocation_id, references(:vocations, on_delete: :nilify_all)
+      add :vocation_id, references(:vocations, on_delete: :restrict), null: false
```

### 2. `lib/nest/agents/agent.ex` — `vocation` becomes required

```elixir
defstruct [
  :name,
  :model,
  :client_config,
  :vocation,                # always set after init
  :workspace_path,
  :tmp_path,
  :tools,
  :llm_metrics,
  mode: "chat",
  chat_state: %__MODULE__.ChatState{}
]

@type t :: %__MODULE__{
        ...
        vocation: Vocations.Vocation.t(),   # was: nil-able
        ...
        }
```

`vocation_id` is not on the Agent struct — it lives in `state.vocation.id`.
The runtime uses `state.vocation` for the struct.

### 3. `lib/nest/agents/agent/init.ex` — require `vocation_id` in attrs

```elixir
def build_state(attrs, client_config) do
  name = Map.fetch!(attrs, :name)
  model = Map.fetch!(attrs, :model)
  vocation_id = Map.fetch!(attrs, :vocation_id)   # was: Map.get
  workspace_path = Map.get(attrs, :workspace_path)
  vocation = Map.get(attrs, :vocation)
  # ... rest unchanged
end
```

`Map.fetch!/2` raises `KeyError` if absent. The supervisor's
`fetch_or_start_agent/1` and the on-demand-load path already pass
`vocation_id` (it's on the agent row, which is now NOT NULL). Test
fixtures are the only callers that need updating.

### 4. `lib/nest/vocations.ex` — `delete_vocation/1` guard

```elixir
def delete_vocation(%Vocation{} = vocation) do
  if agents_using_vocation?(vocation.id) do
    {:error, :agents_using_vocation}
  else
    Repo.delete(vocation)
  end
rescue
  Ecto.ConstraintError -> {:error, :agents_using_vocation}
end

defp agents_using_vocation?(vocation_id) do
  from(a in Nest.Agents.PersistedAgent, where: a.vocation_id == ^vocation_id)
  |> Repo.exists?()
end
```

The pre-check is friendlier (explicit error). The `rescue` catches the
race (concurrent agent insert between the check and the delete).

### 5. `lib/nest/agents/agent/compaction.ex` — pin the compactor's contract

The compactor's `consume_quietly/2` (or a wrapper) re-tags the LLM's
response so production matches the test fixture's expectation that
`new_messages` starts with `{:system, _}`. This is already the case in
production via `wrap_summary/2` in `lib/nest/tokens/compactor.ex`, but
the contract is undocumented. Add a `@doc` to `wrap_summary/2` and to
`Compactor.compact/3` explicitly stating the invariant.

### 6. `lib/nest/agents/agent/handlers/compaction_handler.ex` — `regenerate_for_compaction/2`

The helper called from both `compaction_done/3` and `task_compaction_done/3`
right before `archive_and_compact/2`.

```elixir
@spec regenerate_for_compaction(Nest.Agents.Agent.t(), [Message.t()]) ::
        {Nest.Agents.Agent.t(), [Message.t()]}
defp regenerate_for_compaction(state, compactor_messages) do
  # Structural invariant: the compactor's new_messages always
  # starts with `{:system, _}`. If it doesn't, something else
  # broke — raise to surface the bug.
  [{:system, %System{parts: [%Part.Text{text: summary_text}]}} | rest] =
    compactor_messages

  case maybe_fresh_vocation(state) do
    nil ->
      {state, compactor_messages}

    fresh_vocation ->
      {state, new_messages, rows_to_persist} =
        rebuild_for_compaction(state, fresh_vocation, summary_text, rest)

      Enum.each(rows_to_persist, &Persistence.insert_message(state.name, &1))
      {state, new_messages}
  end
end

defp maybe_fresh_vocation(state) do
  case Vocations.get_vocation(state.vocation.id) do
    %Vocation{} = v -> v
    nil ->
      Logger.warning(
        "Vocation #{state.vocation.id} not found during compaction; using cached state."
      )
      nil
  end
rescue
  error ->
    Logger.warning(
      "Vocation lookup failed during compaction: #{inspect(error)}. Using cached state."
    )
    nil
end
```

`rebuild_for_compaction/4` does the actual work:

1. Re-render the system prompt via `SystemPrompt.compose_vocation_config/3`
   with the fresh `vocation`, current `state.workspace_path`, and
   `{state.llm_metrics.context_limit, state.llm_metrics.context_limit_source}`.
2. Re-build `state.tools` via `Tools.get_functions/3` with the fresh
   `vocation.tools`, current `state.workspace_path`, and existing
   `state.tmp_path`.
3. Re-resolve `state.llm_metrics.context_limit` and `source` via
   `Init.initial_context_limit/1`.
4. Set `state.vocation` to the fresh struct.
5. Build the new `messages` list:
   - Position 0: `{:system, %System{index: marker_index + 1, parts: [%Part.Text{text: fresh_prompt}]}}`
   - Position 1: `{:user, %User{index: marker_index + 2, parts: [%Part.Text{text: "Summary of earlier conversation:\n\n<summary_text>"}]}}`
   - Positions 2+: the compactor's `rest` (user/assistant/tool messages, with the leading system message already dropped).
6. Return `{state, new_messages, rows_to_persist}` where `rows_to_persist`
   is the list of `{role, struct}` tuples in index order (one per new
   message).

`marker_index = state.chat_state.next_message_index` (matching
`compaction_lifecycle.ex:30`).

### 7. Call sites in `compaction_handler.ex`

```elixir
# compaction_done/3 line 54 (three continuation paths share this)
{state, new_messages} = regenerate_for_compaction(state, new_messages)
state = archive_and_compact(state, new_messages)

# task_compaction_done/3 line 112
{state, new_messages} = regenerate_for_compaction(state, new_messages)
state = archive_and_compact(state, new_messages)
```

Continuation recipients (`ChatPipeline.resume_after_compaction/3` for chat,
`send(task_pid, ...)` for preflight and task) receive the modified
`new_messages` (post-regeneration).

### 8. `priv/repo/seeds.exs` — add "Default" vocation

```elixir
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Default",
    description: "A minimal default vocation for agents without a specific role",
    system_prompt: "You are a helpful assistant.",
    tools: ["context"],
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
      }
    }
  })
```

Used by tests that need "any vocation" without picking a specific one.

### 9. Test fixture sweep

Find every test helper that creates an agent with `vocation_id: nil` and
update to use a real vocation id. The pattern is something like:

```elixir
defp agent_attrs(name) do
  %{
    name: name,
    model: %{name: "test-model", provider: "test"},
    workspace_path: nil,
    vocation_id: default_vocation_id()
  }
end
```

Where `default_vocation_id/0` either (a) creates a Default vocation in
`setup` and returns its id, or (b) uses one of the seeded vocations
("Programmer", "Chat Buddy", or the new "Default"). Recommend (a) — test-local
Default insertion keeps the test isolated and doesn't depend on seed order.

## DB rows after a compaction

| Index | In-memory | DB | Persisted by |
|------:|-----------|----|--------------|
| `0..N-1` (pre-compaction) | moved to `state.chat_state.history` | `archived_at` set | `Persistence.archive_and_compact/4` (existing) |
| `N` | new compaction marker in `state.chat_state.history` | new `role: "compaction"` row | `Persistence.archive_and_compact/4` (existing) |
| `N+1` | fresh `{:system, _}` at position 0 | new `role: "system"` row | `regenerate_for_compaction/2` (NEW) |
| `N+2` | `{:user, _}` "Summary of earlier conversation" at position 1 | new `role: "user"` row | `regenerate_for_compaction/2` (NEW) |
| `N+3..N+M+1` | compactor's user/assistant/tool messages | new rows with the compactor's roles | `regenerate_for_compaction/2` (NEW) |

On a subsequent BEAM restart, the on-demand-load path reads
`state.chat_state.messages` from the DB. The post-compaction state is
the live state. The compaction now actually shrinks the agent's context
across restarts.

## Tests

### `test/nest/vocations_test.exs`

- New: `delete_vocation/1 returns :agents_using_vocation when an agent references the vocation`.
- New: `delete_vocation/1 deletes successfully when no agent references the vocation` (regression — old behavior preserved for the no-references case).
- New: `delete_vocation/1 with a concurrent agent insert returns :agents_using_vocation` (FK constraint catches the race).

### `test/nest/agents/agent_compaction_test.exs` (new `describe "system prompt regeneration"`)

1. Position 0 reflects the latest `vocation.system_prompt` after compaction.
2. Position 0 reflects a mutated `AGENTS.md` on disk after compaction.
3. `state.vocation` is updated to the fresh struct.
4. `state.tools` is rebuilt from fresh `vocation.tools`.
5. `state.llm_metrics.context_limit` reflects the resolved value.
6. Encoded summary-as-user is at position 1 when compactor's output starts with a system message.
7. The preflight path regenerates the system prompt.
8. The context-tool path regenerates the system prompt.
9. `Vocations.get_vocation` returns nil: graceful fallback (cached state, warning logged).
10. `Vocations.get_vocation` raises (transient DB error): graceful fallback.

### `test/nest/agents/agent_compaction_persistence_test.exs` (NEW file)

1. Fresh system message is in the messages table at `marker_index + 1`.
2. Encoded summary user message is in the messages table at `marker_index + 2`.
3. Compactor's other output is in the messages table.
4. A BEAM restart after compaction loads the post-compaction state (regression for the latent gap).

### `test/nest/agents/agent_agents_md_test.exs`

- New: AGENTS.md changes between init and compaction are reflected in the regenerated system prompt.

### `test/nest/agents/agent_compaction_consistency_test.exs` (NEW file)

Pins the compactor's output contract that the handler relies on:

1. `compactor's new_messages starts with the original system message at position 0`.
2. `compactor's new_messages has the head summary as a {:system, _} at position 1`.
3. `compactor's new_messages preserves the last user and its responses at the end`.
4. `tail-summary branch produces [system, head_summary, last_user, tail_summary]`.
5. `too-short input returns unchanged`.

## Files changed (summary)

| File | Change |
|------|--------|
| `priv/repo/migrations/20260629033544_create_agent_persistence.exs` | One-line edit: `on_delete: :nilify_all` → `on_delete: :restrict`, add `null: false` |
| `lib/nest/agents/agent.ex` | Type spec: `vocation: nil \| Vocation.t()` → `vocation: Vocation.t()` |
| `lib/nest/agents/agent/init.ex` | `Map.get(attrs, :vocation_id)` → `Map.fetch!(attrs, :vocation_id)` |
| `lib/nest/vocations.ex` | `delete_vocation/1` returns `{:error, :agents_using_vocation}`; add `agents_using_vocation?/1` |
| `lib/nest/agents/agent/compaction.ex` | Document the compactor's output contract in moduledoc and `wrap_summary/2` |
| `lib/nest/tokens/compactor.ex` | Document the output contract in `Compactor.compact/3` and `wrap_summary/2` |
| `lib/nest/agents/agent/handlers/compaction_handler.ex` | New `regenerate_for_compaction/2` helper; call from `compaction_done/3` and `task_compaction_done/3` |
| `priv/repo/seeds.exs` | Add "Default" vocation |
| `test/support/fixtures/*` (sweep) | Update `agent_attrs`-style helpers to use a real vocation id |
| `test/nest/vocations_test.exs` | New `delete_vocation/1` tests |
| `test/nest/agents/agent_compaction_test.exs` | New `describe "system prompt regeneration"` block |
| `test/nest/agents/agent_compaction_persistence_test.exs` | NEW file |
| `test/nest/agents/agent_agents_md_test.exs` | 1 new test |
| `test/nest/agents/agent_compaction_consistency_test.exs` | NEW file |

## Verification

1. `mix ecto.reset` — applies the edited migration cleanly; dev DB has the new schema.
2. Postgres check: `\d agents` shows `vocation_id | bigint | not null` and the FK with `ON DELETE RESTRICT`.
3. `mix precommit` — 740+ BEAM tests, 0 new failures; credo 0 issues; coverage ≥ 90%.
4. `mix test test/nest/vocations_test.exs` — new + existing tests pass.
5. `mix test test/nest/agents/` — all new + existing tests pass.
