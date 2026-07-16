defmodule Nest.Repo.Migrations.CreateMessages do
  @moduledoc """
  The `messages` table. One row per chat message (system, user,
  assistant, tool, or compaction).

  ## Append-only shape

  The table is append-only for its own rows: there are no
  UPDATEs against the `messages` rows themselves. Active-vs-history
  is a view, not a flag — `agents.last_compaction_index` is the
  boundary, and `Persistence.load_messages/1` returns the full
  ordered sequence (active + history + compaction markers).
  Partition into `state.chat_state.messages` (active) and
  `state.chat_state.history` (history) happens at agent-init
  time based on that pointer.

  Only `agents.next_message_index` and
  `agents.last_compaction_index` are UPDATEd on the agents row;
  the `messages` rows themselves are INSERT-only.

  ## Columns

  * `agent_id` — FK to `agents.id` with `ON DELETE CASCADE`.
    Deleting an agent (a rare admin op) drops its messages too;
    vocations and other reference data outlive agents.
  * `message_index` — the agent-scoped message index.
    `(agent_id, message_index)` is `UNIQUE`; restored agents
    preserve order from this column.
  * `role` — string discriminator: `"system"`, `"user"`,
    `"assistant"`, `"tool"`, `"compaction"`. Used by
    `load_messages/1` to fold rows back into the right
    `Message` struct variant.
  * `content` — jsonb map that mirrors the runtime `Message`
    struct's wire format (see `Message.to_json/1`). Every role
    has a `parts` list (the same `Nest.Messages.Part` structs
    the runtime uses); the assistant role additionally carries
    `usage`, `finishReason`, `model`, `metadata`, and `apiLogs`
    keys. The optional top-level `tokens` key carries the
    estimator's token count for that message.
  * `metadata` — jsonb map; nullable. Reserved for runtime
    metadata that doesn't belong in `content`.
  * `compaction_archived_count` — only meaningful for
    `role: "compaction"` rows; carries the count of messages
    compacted away by that boundary.
  * `compaction_occurred_at` — only meaningful for
    `role: "compaction"` rows; when the compaction happened.
  * `compaction_tokens_compacted` / `_to` — only meaningful for
    `role: "compaction"` rows; the token-count view of the
    same boundary (tokens before / after the compaction).
    Both nullable: nil for non-compaction rows and for any
    compaction marker rows persisted before this column was
    introduced. The UI renders absent stats as
    "Context compacted (N archived)" without a token count.
  * `inserted_at` — set by Ecto's `timestamps(updated_at: false)`.
    No `updated_at`: rows are INSERT-only.

  ## FTS

  `search_vector` is a generated tsvector over the text content
  of every part (`jsonb_path_query_array(content,
  '$.parts[*].text')::text`). Stored, not virtual, so the GIN
  index can be used. Searches hit this column; the `messages`
  table itself never needs to be re-tokenized at query time.

  The expression skips rows that have no text content (e.g.
  an assistant message with only `tool_use` parts) by coercing
  the `jsonb_path_query_array` result to `text` and wrapping
  in `coalesce(..., '')`.

  Done as raw SQL because Ecto's `add` doesn't model Postgres
  `GENERATED ... STORED` columns.
  """

  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :agent_id,
          references(:agents, column: :id, on_delete: :delete_all),
          null: false

      add :message_index, :integer, null: false
      add :role, :string, null: false
      add :content, :map, null: false
      add :metadata, :map
      add :compaction_archived_count, :integer
      add :compaction_occurred_at, :utc_datetime
      add :compaction_tokens_compacted, :integer
      add :compaction_tokens_compacted_to, :integer
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:messages, [:agent_id, :message_index])

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
