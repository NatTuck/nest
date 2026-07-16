defmodule Nest.Repo.Migrations.CreateVocations do
  @moduledoc """
  The `vocations` table. Each row is a named role/system-prompt
  catalog that an agent selects from at start time.

  ## Shape

  * `name` — the human-readable identifier (e.g. `"Default"`,
    `"Programmer"`). Unique in spirit but not enforced by the
    schema; `Vocations.upsert_vocation/1` does a name-keyed
    upsert so the row identity is the name.
  * `description` — short summary for the UI/lobby.
  * `system_prompt` — the body of the system message that
    vocation's modes are composed around. Edited in the seed
    file (`priv/repo/seeds.exs`) and shipped to runtime via
    `Vocations.upsert_vocation/1`.
  * `tools` — the full list of tool names this vocation may
    advertise to its modes. Stored as a Postgres
    `varchar[]` (not jsonb) so it's queryable with array
    operators; the runtime filter (`Config.filter_tools_for_depth/3`)
    picks a subset per mode based on caps and depth.
  * `modes` — a jsonb map. Each top-level key is a mode name
    (e.g. `"chat"`, `"build"`, `"plan"`); each value is a map
    with a `caps` key (the sandbox capability map passed to
    `Nest.Sandbox.build/3`) and an optional `description`
    string the LLM's system-prompt catalog can render.

  ## Seeding

  Populated by `priv/repo/seeds.exs` via the
  `mix ecto.setup` alias. The seed file uses
  `Vocations.upsert_vocation/1` so re-running it updates
  existing rows (system prompts, modes, tools) in place
  rather than failing on duplicate names or creating a
  second row.

  ## Why no `UNIQUE` on `name`

  `Vocations.upsert_vocation/1` enforces name uniqueness
  in Elixir (it does a SELECT-then-INSERT-or-UPDATE) so
  a DB constraint would just produce the same conflict
  after a less helpful error message. The application
  layer is the only path that writes this table.
  """

  use Ecto.Migration

  def change do
    create table(:vocations) do
      add :name, :string
      add :description, :string
      add :system_prompt, :text
      add :tools, {:array, :string}, default: []
      add :modes, :map

      timestamps(type: :utc_datetime)
    end
  end
end
