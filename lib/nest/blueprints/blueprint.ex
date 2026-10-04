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

  * `root_vocation` — the **slug** of the root agent's vocation
    when a space is created from this blueprint. Always set.
  * `spawnable_vocations` — whitelist of vocation **slugs** the
    space's agents are allowed to spawn via the `agents-spawn`
    tool. `[]` (or `nil`) means **unrestricted** — any
    vocation may be spawned. A non-empty list is a strict
    whitelist; `agents-spawn` rejects vocations outside it.
    A space without a blueprint (or with a missing blueprint)
    is also unrestricted.
  * `workspace_template` — map of initial workspace files.
    Seeding is deferred; the column exists for future use.
  * `main_view_config` — map consumed by the Phase 4 Main
    View component to pick the layout. Empty by default.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Nest.Slug

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :root_vocation,
             :spawnable_vocations,
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
    field :root_vocation, :string
    field :spawnable_vocations, {:array, :string}, default: []
    field :workspace_template, :map, default: %{}
    field :main_view_config, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          root_vocation: String.t() | nil,
          spawnable_vocations: [String.t()],
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
      :root_vocation,
      :spawnable_vocations,
      :workspace_template,
      :main_view_config
    ])
    |> validate_required([:name, :root_vocation])
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
            put_change(changeset, :slug, Slug.from_name(name))

          _ ->
            changeset
        end
    end
  end

  # Guards the spawnable-vocation whitelist shape (no dupes, all
  # entries non-empty strings) so seed data can't ship a malformed
  # list that would crash `agents-spawn` when it reads it.
  defp validate_spawnable_vocations(changeset) do
    case get_field(changeset, :spawnable_vocations) do
      nil ->
        changeset

      slugs when is_list(slugs) ->
        valid? =
          Enum.all?(slugs, &(is_binary(&1) and &1 != "")) and
            length(Enum.uniq(slugs)) == length(slugs)

        if valid? do
          changeset
        else
          add_error(changeset, :spawnable_vocations, "must be unique non-empty strings")
        end

      _other ->
        add_error(changeset, :spawnable_vocations, "must be a list of strings")
    end
  end
end
