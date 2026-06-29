# Plan: Persistent Agents

## Goal

Persist agent identity and full conversation history in Postgres so that
killing the BEAM and restarting restores state. Concurrently, refactor the
runtime Message structs from flat fields (`content`, `thinking`,
`tool_calls`) to a parts-based representation so the DB schema and the
runtime shape align.

## Decisions locked in this round

- **Two tables, not three.** `agents` + `messages`. `api_logs` was redundant
  with messages — its only unique data (`usage`, `finish_reason`, `model`)
  folds into `messages.content` jsonb. No request payloads stored (O(N²)
  duplication; derivable on demand from message history + agent config).
- **One row per message, content as opaque jsonb.** No `message_parts`
  table. The DB shape is the same as the runtime shape; no translation
  layer.
- **FTS via generated tsvector.** Postgres extracts text from
  `content.parts[*].text` on insert/update; GIN index for fast lookup.
- **Runtime goes to parts now.** `System`, `User`, `Assistant`, `Tool`
  structs all carry `parts: [%Part{}]` instead of bucketed fields.
  `Compaction` stays as-is (no content, just marker data).
- **Sync write per message.** `Agent.__append_message__/2` does an
  in-process `Repo.insert` on each new message. No batching for v1.
- **Lazy restore on `Supervisor.get_agent/1`.** Agents not auto-restarted
  on boot; they're restored when something looks up an ID that's not in
  the in-process Registry.

## Schema

Single migration:

```elixir
create table(:agents, primary_key: false) do
  add :id, :string, primary_key: true
  add :vocation_id, references(:vocations, on_delete: :nil)
  add :model_name, :string, null: false
  add :model_provider, :string
  add :mode, :string, default: "chat", null: false
  add :workspace_path, :string
  add :next_message_index, :integer, default: 0, null: false
  timestamps(type: :utc_datetime)
end

create index(:agents, [:vocation_id])

create table(:messages, primary_key: false) do
  add :id, :bigserial, primary_key: true
  add :agent_id, :string, null: false
  add :message_index, :integer, null: false
  add :role, :string, null: false
  add :content, :map, null: false                  # jsonb
  add :timestamp, :utc_datetime, null: false
  add :metadata, :map
  add :compaction_archived_count, :integer
  add :compaction_occurred_at, :utc_datetime
  add :archived_at, :utc_datetime
end

create unique_index(:messages, [:agent_id, :message_index])
create index(:messages, [:agent_id, :archived_at])

# Generated tsvector + GIN — raw SQL because Ecto's :map doesn't model
# generated columns.
execute("""
ALTER TABLE messages ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english',
      coalesce(jsonb_path_query_array(content, '$.parts[*].text')::text, ''))
  ) STORED
""")

execute("CREATE INDEX messages_search_idx ON messages USING gin(search_vector)")
```

`messages.content` jsonb shape:

```json
{
  "parts": [
    {"kind": "text", "text": "Let me check"},
    {"kind": "thinking", "thinking": "...", "signature": "..."},
    {"kind": "tool_use", "id": "call_1", "name": "read_file", "arguments": {...}}
  ],
  "usage": {"input_tokens": 100, "output_tokens": 50, "total_tokens": 150},
  "finish_reason": "tool_calls",
  "model": "claude-3-opus-20240229"
}
```

For non-assistant messages, `parts` is populated; `usage`/`finish_reason`/
`model` are absent (jsonb allows this naturally).

## Files to create

1. `priv/repo/migrations/<ts>_create_agent_persistence.exs` — schema above.
2. `lib/nest/agents/persisted_agent.ex` — Ecto schema for `agents` table.
3. `lib/nest/agents/persisted_message.ex` — Ecto schema for `messages`
   table; `from_runtime/2` and `to_runtime/1` helpers.
4. `lib/nest/messages/part.ex` — Part struct module (Text, Thinking,
   ToolUse, ToolResult, Refusal) with `kind/1` and `to_json/1`.

## Part module shape

```elixir
defmodule Nest.Messages.Part do
  defmodule Text,       do: defstruct [:text]
  defmodule Thinking,   do: defstruct [:thinking, :signature]
  defmodule ToolUse,    do: defstruct [:id, :name, :arguments]
  defmodule ToolResult, do: defstruct [:tool_call_id, :name, :content, :is_error]
  defmodule Refusal,    do: defstruct [:refusal]

  @type kind :: :text | :thinking | :tool_use | :tool_result | :refusal
  @type t :: %Text{} | %Thinking{} | %ToolUse{} | %ToolResult{} | %Refusal{}

  @spec kind(t()) :: kind()
  def kind(%Text{}),       do: :text
  def kind(%Thinking{}),   do: :thinking
  def kind(%ToolUse{}),    do: :tool_use
  def kind(%ToolResult{}), do: :tool_result
  def kind(%Refusal{}),    do: :refusal

  @spec to_json(t()) :: map()
  def to_json(%Text{text: t}),
    do: %{"kind" => "text", "text" => t}
  def to_json(%Thinking{thinking: t, signature: s}),
    do: %{"kind" => "thinking", "thinking" => t, "signature" => s}
  def to_json(%ToolUse{id: id, name: n, arguments: a}),
    do: %{"kind" => "tool_use", "id" => id, "name" => n, "arguments" => a}
  def to_json(%ToolResult{} = r),
    do: %{"kind" => "tool_result", "toolCallId" => r.tool_call_id,
          "name" => r.name, "content" => r.content, "isError" => r.is_error}
  def to_json(%Refusal{refusal: r}),
    do: %{"kind" => "refusal", "refusal" => r}
end
```

## Runtime struct changes

```elixir
defmodule Nest.Messages.System do
  defstruct [:index, :parts, :timestamp, :metadata, :api_logs]
end

defmodule Nest.Messages.User do
  defstruct [:index, :parts, :timestamp, :metadata, :api_logs]
end

defmodule Nest.Messages.Assistant do
  defstruct [:index, :parts, :usage, :finish_reason, :model,
            :timestamp, :metadata, :api_logs]
end

defmodule Nest.Messages.Tool do
  defstruct [:index, :parts, :timestamp, :metadata, :api_logs]
end

defmodule Nest.Messages.Compaction do
  # unchanged — no parts, marker data only
  defstruct [:index, :archived_count, :occurred_at, :metadata]
end
```

`Assistant` gains `usage`, `finish_reason`, `model` fields (populated
when the message is built from an `LLM.RunResponse`). These persist
into `messages.content` jsonb alongside `parts`.

`Message.t()` (in `lib/nest/messages/message.ex`) type stays as the
tagged tuple; `to_json/1` for each role walks `msg.parts`.

## Files to modify (runtime)

- `lib/nest/messages/system.ex`, `user.ex`, `assistant.ex`, `tool.ex` —
  drop flat fields, add `:parts` (and `:usage`/`:finish_reason`/`:model`
  for Assistant).
- `lib/nest/messages/message.ex` — `to_json/1` walks `msg.parts`.
- `lib/nest/agents/agent/init.ex` — `initial_messages_with_system/1`
  builds `System{parts: [%Text{text: system_prompt}]}`.
- `lib/nest/agents/agent/chat_pipeline.ex` — `build_user_message` builds
  `User{parts: [%Text{text: input_with_mode_prefix}]}`.
- `lib/nest/agents/agent/chat_turn.ex` — LLM response → Assistant
  message: walk response fields, build parts list, populate
  `usage`/`finish_reason`/`model`.
- `lib/nest/agents/agent/compaction.ex` — `assign_indices/2` walks parts.
- `lib/nest/agents/agent.ex` — `__append_message__/2`,
  `__archive_and_compact__/2`, `handle_call(:get_messages)`,
  `handle_call(:get_messages_with_cancelled)`, `handle_call(:get_public_info)`.
- `lib/nest/agents/agent/broadcasts.ex` — wire format walks parts.
- `lib/nest/agents/agent/handlers/*.ex` — anything touching message
  fields.
- `lib/nest/tools/**` — `Tool{tool_results: [...]}` →
  `Tool{parts: [%Part.ToolResult{...}, ...]}` at construction sites.
- `lib/nest/llm/runner.ex` — `RunResponse` to Assistant message parts.

## Persistence layer (`lib/nest/persistence.ex` — extend existing)

```elixir
# Insert or update the agents row.
def upsert_agent(attrs) :: {:ok, PersistedAgent.t()} | {:error, Ecto.Changeset.t()}

# Insert a runtime message into the messages table.
def insert_message(agent_id, {role, struct}) :: {:ok, PersistedMessage.t()} | {:error, ...}

# Mark messages [first..last] as archived, insert compaction marker
# at last + 1, all in one transaction. Returns the new compaction row.
def archive_and_compact(agent_id, first_index, last_index, archived_count) ::
        {:ok, PersistedMessage.t()} | {:error, ...}

# Load active messages (archived_at IS NULL), ordered by message_index.
def load_active_messages(agent_id) :: [{atom(), struct()}]

# Lazy restore: load agent row + active messages + pre-fetch vocation.
def restore_agent(id) :: {:ok, agent_attrs_map()} | {:error, :not_found}

# Update next_message_index after an append.
def update_next_message_index(agent_id, new_index) :: {:ok, ...} | {:error, ...}
```

`PersistedMessage.from_runtime/2` walks the runtime tuple's `parts`
list and produces the jsonb `content` map plus
`compaction_archived_count`/`compaction_occurred_at` for compaction
messages.

`PersistedMessage.to_runtime/1` inverts: walks `content.parts`, builds
the appropriate runtime struct (`System`/`User`/`Assistant`/`Tool`)
with `parts: [...]`.

`upsert_agent/1` uses
`Repo.insert(changeset, on_conflict: [set: [...]], conflict_target: :id)`
so re-creating an agent with the same ID just updates the config.

## Wiring

- `Nest.Agents.Supervisor.start_agent/1` — after `start_child` succeeds,
  call `Persistence.upsert_agent/1`. Failure logs and continues
  (in-memory agent stays valid).
- `Nest.Agents.Supervisor.get_agent/1` — if Registry lookup returns
  `:not_found`, fall back to `Persistence.restore_agent/1` and start a
  fresh GenServer. Returns `{:ok, pid}` or `{:error, :not_found}`.
- `Agent.__append_message__/2` — after appending to in-memory
  `messages`, call `Persistence.insert_message(state.id, stamped)` and
  `Persistence.update_next_message_index(state.id, index + 1)`. Runs
  in the agent process; tests rely on `$callers` walking to the test
  process's sandboxed connection.
- `Agent.__archive_and_compact__/2` — after moving messages from
  `messages` to `history` in memory, call
  `Persistence.archive_and_compact(state.id, first_index, last_index, archived_count)`.
- `Agent.terminate/2` — no special handling. In-flight state
  (streaming_acc, status, cancelled, pending_children, chat_turn_pid)
  is NOT persisted. On restart the agent starts fresh with persisted
  message history; user re-sends if their last message was interrupted.

## Tests to add

- `test/nest/messages/part_test.exs` — Part struct tests
  (`kind/1`, `to_json/1`).
- `test/nest/agents/persistence_test.exs`:
  - Round-trip: insert agent + messages, query back, verify reconstructed
    state matches (parts preserved in order).
  - Compaction: archive messages, verify `archived_at` set + compaction
    marker exists.
  - Restore: insert agent + messages, then `Supervisor.get_agent/1`,
    verify live agent's `state.chat_state.messages` matches.
  - `api_logs` data lives on the message: usage/finish_reason survive
    round-trip.

## Tests to update

- All message-shape assertions rewritten to walk `parts` instead of
  `content`/`thinking`/`tool_calls`/`tool_results`.
- Tool tests where `tool_results: [...]` was constructed — switch to
  `parts: [%ToolResult{...}, ...]`.
- JS-side: MessageContent component tests update for parts rendering.

## Files to update (JS wire format)

- `assets/js/components/MessageContent.jsx` — render `msg.parts` in
  order, dispatch on `part.kind`.
- `assets/js/channels.js` — wire format expectations (now `{parts:
  [...]}` not `{content, toolCalls, thinking}`).
- `assets/js/store/index.js` — message accumulation, delta merging
  (parts-aware).

## PR sequencing (single PR, ordered commits)

1. Add `Part` module + tests.
2. Refactor System/User/Assistant/Tool structs to `parts`; update
   `to_json/1`.
3. Update all construction sites (init, chat_pipeline, chat_turn,
   tools).
4. Update all consumer sites (agent state, broadcasts, compaction,
   handlers).
5. Update message-shape assertions in tests; add Part tests.
6. Update JS (MessageContent, channels, store).
7. Add migration.
8. Add PersistedAgent / PersistedMessage schemas + persistence module.
9. Wire up `Supervisor.start_agent/1` upsert + lazy restore.
10. Add persistence tests.
11. `mix precommit` clean.

## Risks

- **Big PR.** ~12 files for runtime, ~3 for DB, ~5 for tests, ~3 for JS.
  Lots of churn.
- **Wire format change.** UI breakage possible if MessageContent doesn't
  get updated atomically with the runtime change.
- **FTS index requires Postgres 12+.** We're on 16, so fine.
- **Generated column performance.** Each insert computes tsvector from
  the jsonb. Fast for our scale, but worth knowing.
- **Multiple messages per turn.** When a turn produces assistant +
  tool_result messages, both are written via `insert_message` (separate
  rows). The agent's `api_logs` data lives on the assistant message
  only. No FK between api_logs and turns (no turns table).

## Verification

- `mix compile --warnings-as-errors` — catches missed `msg.content`
  access etc.
- `mix test` — 669 existing tests pass; new tests bring count up.
- `mix test --cover` — coverage maintained.
- `mix precommit` — credo, format, biome, tests all clean.
- `MIX_ENV=test mix ecto.drop && mix ecto.create && mix ecto.migrate`
  on a fresh DB — migration runs cleanly.
- Manual: start an agent, run a chat (verify messages persist), kill
  BEAM, restart, `Supervisor.get_agent(id)` — verify message history
  restored.

## Out of scope for this PR

- Cross-agent LLM-call analytics (no `llm_calls` table; would belong in
  a separate observability concern).
- FTS query UI (the index is here, but searching for messages in the
  chat UI is a separate feature).
- Resumable streaming state (in-flight chat on restart is lost; user
  re-sends).
- Persisting `usage_totals` / `descendant_usage` from `llm_metrics`
  (trivially added later as a column or jsonb).
- Persisting `client_config` (api_key etc.) — reconstructed at startup
  from `DotConfig`, same as today's behavior.