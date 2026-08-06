defmodule Nest.Repo.Migrations.AddUserToAgents do
  @moduledoc """
  Adds the multi-user identity columns to the `agents` table.

  ## `created_by_user_id`

  Integer FK to `users.id`. `ON DELETE SET NULL` so deleting a
  user account orphans their agents but doesn't drop them — the
  operator can re-assign ownership via a backfill script.

  Nullable in the migration; `Nest.PersistedAgent`'s application-
  level changeset will validate its presence for newly-inserted
  agents created through `Agents.create_agent/2` after the
  bootstrap transition (the API takes a `current_user` and
  threads it through). Existing rows (any pre-multi-user agent)
  remain NULL until an operator runs the backfill script in
  `priv/repo/backfill_agent_owners.exs`.

  ## `shared`

  Boolean visibility flag. When `true`, every authenticated user
  can see and chat with the agent in the lobby; the owner still
  has edit/delete rights. Default `false` keeps the privacy
  guarantee for existing rows and for new agents created without
  an explicit `shared: true` opt-in.

  A partial index on `shared` keeps the lobby's "shared agents"
  query fast as the catalog grows.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :created_by_user_id,
          references(:users, on_delete: :nilify_all),
          null: true

      add :shared, :boolean, default: false, null: false
    end

    create index(:agents, [:created_by_user_id])
    create index(:agents, [:shared], where: "shared", name: :agents_shared_idx)
  end
end
