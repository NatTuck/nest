defmodule Nest.Blueprints.Blueprint do
  @moduledoc """
  Ecto schema for the `blueprints` table.

  A Blueprint is a template for creating a Space: it pins
  the root agent's vocation, names the sub-agent vocations
  the space's agents are allowed to spawn, seeds a workspace
  template, and drives the Main View layout.

  ## Identity

  * `id` — server-internal `bigserial`. FK target for
    `spaces.blueprint_id`.
  * `name` — human-readable blueprint name. Globally unique.
  * `slug` — URL-safe identifier derived from `name`. Globally
    unique.

  ## Shape

  * `root_vocation_id` — the root agent's vocation when a
    space is created from this blueprint. Always set.
  * `spawnable_vocation_ids` — whitelist of vocation ids the
    space's agents are allowed to spawn via the `spawn_agent`
    tool. `[]` (or `nil`) means **unrestricted** — any
    vocation may be spawned. A non-empty list is a strict
    whitelist; `spawn_agent` rejects vocations outside it.
    A space without a blueprint (or with a missing blueprint)
    is also unrestricted.
  * `workspace_template` — map of initial workspace files.
    Seeded by `Spaces.create_space_with_root_agent/2` when
    the blueprint is non-nil.
  * `main_view_config` — map consumed by the Phase 4 Main
    View component to pick the layout. Empty by default.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :root_vocation_id,
             :spawnable_vocation_ids,
             :workspace_template,
             :main_view_config,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :id, autogenerate: true}
  schema "blueprints" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :root_vocation_id, :integer
    field :spawnable_vocation_ids, {:array, :integer}, default: []
    field :workspace_template, :map, default: %{}
    field :main_view_config, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          root_vocation_id: integer() | nil,
          spawnable_vocation_ids: [integer()],
          workspace_template: map(),
          main_view_config: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  def changeset(blueprint, params) do
    blueprint
    |> cast(params, [
      :name,
      :slug,
      :description,
      :root_vocation_id,
      :spawnable_vocation_ids,
      :workspace_template,
      :main_view_config
    ])
    |> validate_required([:name, :root_vocation_id])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> validate_spawnable_vocations()
  end

  # Same slug auto-gen rule as `Space`: only generate when
  # the caller didn't supply one, and only after `:name`
  # has been validated.
  defp maybe_generate_slug(%Ecto.Changeset{} = changeset) do
    case fetch_change(changeset, :slug) do
      {:ok, slug} when is_binary(slug) and slug != "" ->
        changeset

      _ ->
        case fetch_change(changeset, :name) do
          {:ok, name} when is_binary(name) ->
            put_change(changeset, :slug, generate_slug(name))

          _ ->
            changeset
        end
    end
  end

  defp generate_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Phase 3 (`agents/spawn`) will check `spawnable_vocation_ids`
  # as a whitelist. For Phase 2 the column exists but is
  # unused; this validator just guards the shape (no dupes,
  # all entries integers) so seed data can't ship a malformed
  # list that would crash Phase 3 when it reads it.
  defp validate_spawnable_vocations(changeset) do
    case get_field(changeset, :spawnable_vocation_ids) do
      nil ->
        changeset

      ids when is_list(ids) ->
        if Enum.all?(ids, &is_integer/1) and length(Enum.uniq(ids)) == length(ids) do
          changeset
        else
          add_error(changeset, :spawnable_vocation_ids, "must be unique integers")
        end

      _other ->
        add_error(changeset, :spawnable_vocation_ids, "must be a list of integers")
    end
  end
end
