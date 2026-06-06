defmodule Nest.Vocations.Vocation do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :system_prompt,
             :tools,
             :modes,
             :inserted_at,
             :updated_at
           ]}

  schema "vocations" do
    field :name, :string
    field :description, :string
    field :system_prompt, :string
    field :tools, {:array, :string}, default: []
    field :modes, :map

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(vocation, attrs) do
    vocation
    |> cast(attrs, [:name, :description, :system_prompt, :tools, :modes])
    |> validate_required([:name, :description, :system_prompt])
  end
end
