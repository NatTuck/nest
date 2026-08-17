defmodule Nest.Spaces.Space do
  @moduledoc """
  Ecto schema for the `spaces` table.

  A Space is a container for a group of collaborating agents
  and their shared environment. Every agent belongs to exactly
  one space.

  ## Identity

  * `id` — server-internal `bigserial`. FK target for `agents.space_id`.
  * `name` — human-readable space name. Globally unique.
  * `slug` — URL-safe identifier derived from `name`. Globally unique.

  ## Multi-user

  * `created_by_user_id` — FK to `users.id`. The user who created
    the space.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :blueprint_id,
             :workspace_path,
             :created_by_user_id,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :id, autogenerate: true}
  schema "spaces" do
    field :name, :string
    field :slug, :string
    field :blueprint_id, :integer
    field :workspace_path, :string
    field :created_by_user_id, :integer

    # Lifecycle. `archived` soft-hides the space from the main
    # space list (`Spaces.list_for_user/1`) and stops its agents.
    # The row and its agents are preserved so the owner can
    # inspect and unarchive it via the archived-spaces view.
    field :archived, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a changeset for inserting or updating a space row.

  Required: `:name`, `:created_by_user_id`. `:slug` is derived
  from `:name` if not provided. `:blueprint_id` and
  `:workspace_path` are optional.
  """
  def changeset(source, params) do
    source
    |> cast(params, [:name, :slug, :blueprint_id, :workspace_path, :created_by_user_id])
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:blueprint_id)
  end

  # Generate a slug from `:name` when the caller didn't supply
  # one. Runs after `validate_required([:name])` so we always
  # have a name to slugify. We deliberately skip the
  # `valid?: true` guard here because the *next* step is
  # `validate_required([:slug])` — the slug we generate makes
  # that validation pass. The `valid?` flag stays false until
  # the trailing validations run.
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
end
