# api_log Persistence Across BEAM Restart

`state.chat_state.messages[i].api_logs` is built up in-memory only.
After a BEAM restart, every message reloads from the DB with
`api_logs: []` — the UI's "API Logs" expander is empty for every
chat, the copy-as-JSON button has nothing to copy, and the
debugging story for "why did the LLM say that?" requires a network
tap. This plan makes api_logs survive restarts without O(N²) growth.

## Why selective persistence

If we naïvely persist every request payload (each carries
`messages[0..idx]` plus tools/tool_choice/model), at 1M context
that's ~200MB per cycle. Compaction cycles can produce tens of
cycles per session → GBs. The asymmetry that's been latent in the
schema:

| Role | What api_logs carry | Typical size |
|---|---|---|
| `:assistant` | response only (text + tool_calls + finish_reason + usage) | a few KB |
| `:user` | request (messages[0..idx] + tools + ...) | tens to hundreds of KB |
| `:tool` | request (continuation call) | tens to hundreds of KB |
| `:system` | never populated in practice; persist `[]` for forward compat | 0 |

So persist `:assistant` (response only), persist `:system` (empty
list), and **don't persist** for `:user`/`:tool` — rebuild the
request payload on restore via the same client
`format_request_payload/2` the live path uses.

## Sequence-number continuity

JS uses `key={log.timestamp}` in `ApiLogsBlock.jsx:66`, NOT `log.id`.
A rebuild can stamp any id it wants; only the timestamp matters
for React reconciliation. (Confirmed by reading the JS.) So the
rebuild emits ids `"<message_index>.000"` (matching what
`Broadcasts.next_api_log_id/2` would have produced at the time
of the original request). Live requests after restore start at
`.001` because the rebuild pre-populates
`state.chat_state.api_log_sequences[idx] = 1` — no id collision.

## Locked design choices

| # | Choice | Value |
|---|---|---|
| 1 | Persisted roles | `:assistant` (response logs), `:system` (empty list) |
| 2 | Rebuilt roles | `:user`, `:tool` (request payload, computed on restore) |
| 3 | Rebuild path | `state.client_config.client.format_request_payload/2` directly (not via `Runner.format_request_payload/3` — no `opts` needed for wire format) |
| 4 | `tool_choice` for rebuilt request | `:auto` (matches the agent's standard chat config; vocation changes mid-conversation aren't supported elsewhere) |
| 5 | `stream` and `metadata` fields on rebuilt `RunRequest` | `stream: true, metadata: %{}` (live defaults; documented as a comment in the rebuild function) |
| 6 | `api_log_sequences` initial map on restore | `%{idx => 1}` for every `:user`/`:tool` index — next live log `.001` (no collision with rebuilt `.000`) |
| 7 | `state.chat_state.api_log_sequences` field shape | unchanged (`Map.t()`); schema doesn't change |
| 8 | Backward compat: rows without `apiLogs` key | Treat as `[]` for `:assistant`/`:system`; rebuild for `:user`/`:tool`. No migration needed — `to_runtime/1` reads `content["apiLogs"]` with a `Map.get(..., [])` fallback |
| 9 | System messages persist empty `apiLogs` | Forward compat for any future logging the system message might accumulate |
| 10 | Where the `Restore` module lives | `lib/nest/agents/agent/restore.ex` (matches the `Compaction.Lifecycle` pattern; pure functions, no GenServer state) |
| 11 | `:assistant`/`:system` row shape | `"apiLogs"` key ALWAYS present (even when empty) — self-documenting |
| 12 | `:user`/`:tool` row shape | `"apiLogs"` key NOT in row content — rebuilt on restore (avoids O(n²) storage cost) |

## `PersistedMessage` changes

`lib/nest/agents/persisted_message.ex`

### `serialize_content/2` (private; update the four public dispatchers)

For `:assistant`:

```elixir
defp serialize_content(:assistant, %Assistant{} = struct) do
  %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
  |> maybe_put("usage", struct.usage)
  |> maybe_put("finishReason", struct.finish_reason)
  |> maybe_put("model", struct.model)
  |> Map.put("apiLogs", Message.format_api_logs(struct.api_logs))
  |> maybe_put("metadata", stringify_keys(struct.metadata))
  |> maybe_put_tokens(struct.tokens)
end
```

The `apiLogs` key is ALWAYS written (per choice #11). For `:system`:

```elixir
defp serialize_content(:system, struct) do
  %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
  |> Map.put("apiLogs", Message.format_api_logs(struct.api_logs))
  |> maybe_put_tokens(struct.tokens)
end
```

For `:user`, `:tool`, `:compaction`: unchanged (don't write `apiLogs`).

### `to_runtime/1`

Four message-role cases; update each:

For `:system`, `:assistant`: read `content["apiLogs"]` (default `[]`) and pass to the runtime struct's `:api_logs`. This is the additive round-trip path.

For `:user`, `:tool`: leave `api_logs: []` (the rebuild path will populate them after `seed_from_db/3`).

### `changeset/2` cast list

The cast list `:agent_id, :message_index, :role, :content, :metadata, :compaction_archived_count, :compaction_occurred_at` stays unchanged — `content` is jsonb and the `apiLogs` key rides along inside it.

## New `Nest.Agents.Agent.Restore` module

`lib/nest/agents/agent/restore.ex`

Pure functions, no GenServer state. Three public functions plus internal helpers:

### `rebuild_request_api_logs/4`

```elixir
@spec rebuild_request_api_logs(
  Nest.Agents.Agent.t(),
  [Message.t()],  # full preloaded sequence (history + messages)
  integer(),       # message_index to rebuild for
  ClientConfig.t() # for format_request_payload
) :: %{id: String.t(), type: :request, payload: map(), timestamp: DateTime.t()}
```

Walks `Enum.take(messages, idx + 1)` (prepended system + every
prior user/assistant/tool), builds a `%RunRequest{
messages: ..., tools: state.tools, tool_choice: :auto, model:
client_config.model, stream: true, metadata: %{}}`, calls
`client_config.client.format_request_payload(request, [])` (no
`opts` — wire format only), wraps the result as `%{id:
format_sequence_id(idx, 0), type: :request, payload: <wire>,
timestamp: DateTime.utc_now()}`.

The `format_sequence_id/2` helper is the inverse of
`Broadcasts.next_api_log_id/2`'s `:io_lib.format("~3..0B.~3..0B",
[idx, seq])` — same id format so the JS sees identical ids to
what the live path would have produced.

The `stream: true, metadata: %{}` defaults match the live path's
`ChatTurn.APILog.request/3`. A code comment documents this.

### `initial_sequences_for/1`

```elixir
@spec initial_sequences_for([Message.t()]) :: %{integer() => non_neg_integer()}
```

Returns `%{idx => 1}` for every `:user`/`:tool` message index in
the preloaded list. Empty for `:assistant`/`:system`. The
caller merges this into `state.chat_state.api_log_sequences`
on init.

The merge needs to preserve any pre-existing keys for `:assistant` indices (none today, but future-proof).

### `attach_rebuilt_api_logs/3`

```elixir
@spec attach_rebuilt_api_logs(
  Nest.Agents.Agent.t(),
  [Message.t()],         # full preloaded sequence (history + messages)
  integer()              # last_compaction_index (boundary)
) :: Nest.Agents.Agent.t()
```

The orchestrating helper called from `Agent.init/1`. Walks the
preloaded list. For every `:user` and `:tool` index whose runtime
`api_logs` is still empty (idempotency guard):

1. Compute the rebuilt request log via `rebuild_request_api_logs/4`.
2. Assign it to `message.api_logs = [rebuilt_entry]`.

Returns the agent state with `:user`/`:tool` messages' `api_logs`
populated and `chat_state.api_log_sequences` initialized via
`initial_sequences_for/1`.

Idempotent: a row that already has a non-empty `api_logs`
(empty `[]`) doesn't get touched. Today the rebuild is the only
writer for `:user`/`:tool`, so this is forward-compat for when we
add a `persistence.api_log` flag in the future.

## `Persistence.build_attrs_for_start/1` extension

`lib/nest/persistence.ex`. Currently returns
`%{name, model, vocation_id, workspace_path, next_message_index,
last_compaction_index, preloaded_messages, vocation}`. Add:

- `:initial_api_log_sequences` — `%{idx => seq}` for `:user`/`:tool`
  rows, computed from `preloaded_messages` via
  `Restore.initial_sequences_for/1`.

The caller `Agent.init/1` already passes through `:preloaded_messages`
and `:last_compaction_index`; the new field follows the same path.

## `Agent.init/1` and `Init.build_state/2` wiring

`lib/nest/agents/agent.ex`:

In `init/1`, after `Init.build_state(attrs, client_config)`:

```elixir
# Restore from DB (existing path).
state =
  Init.seed_from_db(
    state,
    Map.get(attrs, :preloaded_messages, []),
    Map.get(attrs, :last_compaction_index, -1)
  )

# Populate user/tool api_logs by replaying the live request
# payload build. Must run AFTER seed_from_db/3 (which partitions
# the preloaded list into history + messages) so the request
# payload can be assembled from the full pre-compaction sequence
# contained in `attrs[:preloaded_messages]`.
state =
  Init.attach_rebuilt_api_logs(
    state,
    Map.get(attrs, :preloaded_messages, []),
    Map.get(attrs, :last_compaction_index, -1)
  )
```

`lib/nest/agents/agent/init.ex`:

A thin delegator in Init that calls into Restore:

```elixir
@doc """
Attach rebuilt api_logs to user/tool messages and seed
chat_state.api_log_sequences. See
`Nest.Agents.Agent.Restore` for the implementation.
"""
def attach_rebuilt_api_logs(state, preloaded, last_compaction_index) do
  Restore.attach_rebuilt_api_logs(state, preloaded, last_compaction_index)
end
```

The `build_chat_state/2` private helper in `Init` already takes
the initial `chat_state` shape; extend it to accept an initial
`api_log_sequences` map (default `%{}`):

```elixir
defp build_chat_state(messages, next_index, api_log_sequences \\ %{}) do
  %Nest.Agents.Agent.ChatState{
    messages: messages,
    next_message_index: next_index,
    streaming_acc: nil,
    status: :idle,
    active_message_index: 0,
    api_log_sequences: api_log_sequences
  }
end
```

`build_state/2` reads the initial sequences from
`attrs[:initial_api_log_sequences]` (default `%{}`) and threads it
through.

## Tests

### New: `test/nest/agents/persisted_message_test.exs`

- `serialize_content` round-trip for `:assistant` with non-empty `api_logs`.
- `serialize_content` round-trip for `:assistant` with empty/nil `api_logs` writes `"apiLogs": []` (NOT omitted).
- `serialize_content` round-trip for `:system` with empty `api_logs` writes `"apiLogs": []`.
- `serialize_content` round-trip for `:user` and `:tool` (NO `apiLogs` key in `content`, even when runtime `api_logs` is set).
- `to_runtime` round-trip preserves `:assistant` `api_logs`.
- Old rows (no `apiLogs` key) read back with empty `api_logs`.

### New: `test/nest/agents/agent/restore_test.exs`

- `rebuild_request_api_logs/4` produces wire-format identical to `Broadcasts.api_log/4`'s live shape (`id`, `timestamp`, `type: :request`, `payload`).
- For a user message at index 5 with prior messages [system@0, user@1, assistant@2, user@5 (target)], the rebuilt payload contains `messages: [system@0, user@1, assistant@2, user@5]` with the wire format from `OpenAIClient.format_request_payload/2`.
- `initial_sequences_for/1` returns `%{user_idx => 1, tool_idx => 1}` and skips `:assistant`/`:system`.
- `attach_rebuilt_api_logs/3` sets `:user`/`:tool` `.api_logs = [rebuilt]` and populates `state.chat_state.api_log_sequences`.
- Idempotent: calling `attach_rebuilt_api_logs/3` twice doesn't double the entries.

### Update: `test/nest/persistence_agents_test.exs`

Add coverage for `:apiLogs` round-trip in `:assistant` messages via `Persistence.insert_message/2` and `to_runtime/1`.

### Add to existing `test/nest/agents/agent_chat_test.exs`

A single end-to-end test: drive a chat turn (user → assistant), kill the agent, restart, verify the new agent's restored `state.chat_state.messages` has the rebuilt request log on the user message and the persisted response log on the assistant message.

## Verification

1. `mix precommit` clean (compile + format + credo + biome + tests).
2. Manual: open agent, send one message, kill BEAM, restart the
   agent channel, click the "API Logs" expander on the user and
   assistant messages — both should show non-empty payloads. The
   user message's payload is the rebuilt request; the assistant's
   is the persisted response payload.
3. The rebuilt payload should match byte-for-byte what the live
   `Broadcasts.api_log/4` would have produced for the same
   messages (test only — production acceptance is the JS renders).

## Out of scope (deferred)

- **Persisting user/tool api_logs** beyond rebuilt requests.
  The strategy is to leave this O(n²)-prone; the rebuild path
  gives parity with what the live path produced.
- **Cleaning up the in-memory `pending_api_logs` queue across
  restarts.** The queue is short-lived (one ChatTurn); if it
  has entries at restart they're simply lost — the rebuild
  re-populates the message-level `api_logs` field, not the
  queue, and the queue's contract is "in-flight broadcast not
  yet attached". Re-fetching the same `api_log` after restart
  is fine because the queue flushes on the next turn.
- **History rebuild on restore.** Separate follow-up; the
  shape is now ready (`history ++ messages` is the single
  consistent sequence).
- **`agents.parent_id`** for subagents. Same single-message-sequence
  shape enables the clone, but the column + tool live in another PR.
