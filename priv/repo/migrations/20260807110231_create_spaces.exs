defmodule Nest.Repo.Migrations.CreateSpaces do
  @moduledoc """
    Create the `spaces` table.

    A Space is a container for a group of collaborating agents
    and their shared environment. Every agent belongs to exactly
    one space.

    ## Columns

    * `name` — human-readable space name (e.g. "clever-raven").
      Globally unique.
    * `slug` — URL-safe identifier derived from `name`. Globally
      unique. Used in routes (`/space/:slug`).
    * `blueprint_id` — optional FK to `blueprints.id` (added in
      Phase 2). Nullable for now.
    * `created_by_user_id` — FK to `users.id`. The user who
      created the space.

  ## Backfill

    Each user gets exactly one primary space, lazily created on
    their first WS connect by `Spaces.ensure_primary_space/1`.
    Agents are assigned to a space at creation time; there is
    no synthetic default space.
  """

  use Ecto.Migration

  def change do
    create table(:spaces, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :blueprint_id, :integer
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:spaces, [:name])
    create unique_index(:spaces, [:slug])
    create index(:spaces, [:created_by_user_id])
  end
end
