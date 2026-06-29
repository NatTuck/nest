defmodule Nest.Repo.Migrations.CreateAgentPersistence do
  @moduledoc """
  Adds the `agents` and `messages` tables that back persistent agent
  state across BEAM restarts.

  ## agents

  One row per agent. The primary key is the agent's string `id`
  (e.g. `"clever-raven"`) — the same key the in-process `Registry`
  uses — so upserts from `Supervisor.start_agent/1` are idempotent
  and the lazy-restore path in `Supervisor.get_agent/1` can fetch
  by id.

  `model` is stored as a jsonb map so we can rehydrate the
  `Nest.LLM.ClientConfig` on restore. `next_message_index` is
  bumped on every persisted message so the restored agent's
  `state.chat_state.next_message_index` is correct on first
  read.

  ## messages

  One row per chat message (system, user, assistant, tool, or
  compaction). The `content` column is a jsonb map that mirrors the
  runtime `Message` struct's shape: every role has a `parts` list
  (the same `Nest.Messages.Part` structs the runtime uses); the
  assistant role additionally carries `usage`, `finish_reason`, and
  `model` keys.

  No `api_logs` table — the response-level metadata (usage,
  finish_reason) is folded into `messages.content` for assistant
  messages, and the request/response payloads are not stored
  (request payloads duplicate the message history, response
  payloads are recomputed by re-issuing the request).

  No `turns` table — a "turn" is implicit in the sequence of
  `messages` rows and the assistant message's `usage` field.

  ## FTS

  `messages.search_vector` is a generated tsvector over the text
  content of every part (`jsonb_path_query_array(content,
  '$.parts[*].text')::text`). Stored, not virtual, so the GIN index
  can be used. Searches hit this column; the `messages` table
  itself never needs to be re-tokenized at query time.

  The expression skips rows that have no text content (e.g. an
  assistant message with only `tool_use` parts) by coercing the
  `jsonb_path_query_array` result to `text` and wrapping in
  `coalesce(..., '')`.
  """

  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :vocation_id, references(:vocations, on_delete: :nilify_all)
      add :model, :map, null: false
      add :workspace_path, :string
      add :next_message_index, :integer, default: 0, null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create table(:messages, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :agent_id,
          references(:agents, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :message_index, :integer, null: false
      add :role, :string, null: false
      add :content, :map, null: false
      add :metadata, :map
      add :inserted_at, :utc_datetime, null: false
      add :archived_at, :utc_datetime
      add :compaction_archived_count, :integer
      add :compaction_occurred_at, :utc_datetime
    end

    create unique_index(:messages, [:agent_id, :message_index])
    create index(:messages, [:agent_id, :archived_at])

    # Generated tsvector + GIN index. Done as raw SQL because
    # Ecto's `add` doesn't model Postgres GENERATED ... STORED
    # columns. The expression extracts every `text` field from
    # the `parts` list and tokenizes it with the english
    # configuration. Empty arrays / non-text parts produce NULL,
    # which `coalesce` converts to '' so the tsvector is well-
    # formed for every row.
    execute("""
    ALTER TABLE messages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector('english',
        coalesce(jsonb_path_query_array(content, '$.parts[*].text')::text, ''))
    ) STORED
    """)

    execute("CREATE INDEX messages_search_idx ON messages USING gin(search_vector)")
  end
end
