defmodule Nest.Repo.Migrations.CreateAgents do
  @moduledoc """
  The `agents` table. One row per agent, keyed by a server-internal
  bigserial `id` (FK target) and a human-readable `name` (the
  identifier used everywhere outside the DB).

  ## Identity

  * `id` — server-internal `bigserial`. FK target for `messages`
    and the self-referential `parent_id`. Callers outside the DB
    never see this number.
  * `name` — the agent's human-readable identifier (e.g.
    `"clever-raven"`). Unique (`UNIQUE (name)` index). Used in
    URL paths, channel topics (`agent:<name>`), Registry keys,
    and the frontend.
  * `vocation_id` — FK to `vocations.id`. `ON DELETE RESTRICT`
    so a vocation cannot be deleted while an agent still uses
    it; vocations are seed-managed reference data and shouldn't
    disappear under live agents.

  ## Runtime state

  * `model` — jsonb map. Persists the `Nest.LLM.ClientConfig`
    enough to rehydrate the LLM client on restore. The
    `model` map shape matches `ClientConfig.to_map/1`.
  * `workspace_path` — host path to the agent's workspace
    directory. Nullable; agents in read-only modes may not
    have one.
  * `next_message_index` — bumped on every persisted message
    so the restored agent's `state.chat_state.next_message_index`
    is correct on first read. Default 0.

  ## Active/history partition

  * `last_compaction_index` — boundary pointer for the
    active/history partition of an agent's messages.

        state.chat_state.messages = messages WHERE message_index > agents.last_compaction_index

    `-1` is the sentinel for "never compacted; the entire
    sequence, including the system prompt at index 0, is in
    `messages`." Bumped atomically by
    `Persistence.record_compaction/5` together with the
    compaction marker INSERT. The `messages` table itself
    is append-only — only `agents.next_message_index` and
    `agents.last_compaction_index` are UPDATEd.

  ## Sub-agent tree

  * `parent_id` — integer `agents.id` of the spawning parent
    (nil for roots). Self-referential FK with
    `ON DELETE SET NULL`: deleting a parent row orphans its
    children with `parent_id: nil` rather than cascading the
    deletion. The runtime supervisor cascades termination
    separately; the DB column is the historical relationship
    only, and orphaning is the right semantic for a deleted
    parent.
  * `depth` — the agent's tree depth (0 for roots;
    `parent.depth + 1` for children). Carries a
    `CHECK (depth >= 0)` constraint as the canonical guard;
    `PersistedAgent.changeset/2` validates the same
    constraint at the application layer to surface the error
    as a changeset error before the DB raises.
  """

  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false
      add :vocation_id, references(:vocations, on_delete: :restrict), null: false
      add :model, :map, null: false
      add :workspace_path, :string
      add :next_message_index, :integer, default: 0, null: false
      add :last_compaction_index, :integer, default: -1, null: false
      add :parent_id, references(:agents, on_delete: :nilify_all)
      add :depth, :integer, default: 0, null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:agents, [:name])

    create constraint(:agents, :depth_non_negative, check: "depth >= 0")
  end
end
