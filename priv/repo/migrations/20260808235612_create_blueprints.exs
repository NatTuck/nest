defmodule Nest.Repo.Migrations.CreateBlueprints do
  @moduledoc """
  Create the `blueprints` table.

  A Blueprint is a template for creating a Space: it pins
  the root agent's vocation, names the sub-agent vocations
  the space's agents are allowed to spawn, seeds a workspace
  template, and drives the Main View layout.

  ## Columns

  * `name` — human-readable blueprint name (e.g. "Tabletop RPG").
    Globally unique.
  * `slug` — URL-safe identifier derived from `name`. Globally
    unique. Used in routes (`/space/new?blueprint=:slug`).
  * `description` — short text shown in the blueprint picker.
  * `root_vocation_id` — FK to `vocations.id`. The vocation
    the root agent runs when a space is created from this
    blueprint. NOT NULL: every blueprint pins a root.
  * `spawnable_vocation_ids` — integer array of vocation ids
    the space's agents are allowed to spawn via the
    `agents/spawn` tool (Phase 3). Empty means "no spawning".
  * `workspace_template` — JSONB map describing the initial
    workspace layout. Empty by default; `workspace_template`
    is consumed by Phase 2's create-from-blueprint flow.
  * `main_view_config` — JSONB map consumed by the Phase 4
    Main View component to pick the layout. Empty by default.

  ## Indexes

  * Unique on `name` and `slug`.
  * Index on `root_vocation_id` (lookups by FK during
    blueprint-driven space creation).

  ## FK on `spaces.blueprint_id`

  A separate migration adds the FK constraint from
  `spaces.blueprint_id` → `blueprints.id` (with
  `on_delete: :nilify_all` so deleting a blueprint detaches
  the spaces without dropping them).
  """

  use Ecto.Migration

  def change do
    create table(:blueprints, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string

      add :root_vocation_id,
          references(:vocations, on_delete: :restrict),
          null: false

      add :spawnable_vocation_ids, {:array, :integer}, default: []
      add :workspace_template, :map, default: %{}
      add :main_view_config, :map, default: %{}

      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:blueprints, [:name])
    create unique_index(:blueprints, [:slug])
    create index(:blueprints, [:root_vocation_id])
  end
end
