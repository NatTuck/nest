defmodule Nest.Vocations.Vocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Nest.Slug

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :system_prompt,
             :tools,
             :inserted_at,
             :updated_at
           ]}

  schema "vocations" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :system_prompt, :string
    field :tools, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          system_prompt: String.t() | nil,
          tools: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  def changeset(vocation, attrs) do
    vocation
    |> cast(attrs, [:name, :slug, :description, :system_prompt, :tools])
    |> validate_required([:name, :description, :system_prompt])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:slug)
  end

  # Derive a slug from `:name` when the caller didn't supply one.
  # Runs after `validate_required([:name])`; the following
  # `validate_required([:slug])` makes an all-symbol name (which
  # slugifies to "") fail loudly rather than inserting a blank slug.
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
end
