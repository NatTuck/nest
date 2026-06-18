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

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          system_prompt: String.t() | nil,
          tools: [String.t()],
          modes: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  def changeset(vocation, attrs) do
    vocation
    |> cast(attrs, [:name, :description, :system_prompt, :tools, :modes])
    |> validate_required([:name, :description, :system_prompt])
    |> validate_modes()
  end

  # Validates the shape of the `modes` JSONB map.
  #
  # Each top-level key is a mode name (string). Each value is a map
  # with a `caps` key holding the sandbox capability map. Optionally
  # a `description` string describes the mode for the LLM's system
  # prompt catalog.
  defp validate_modes(changeset) do
    case get_field(changeset, :modes) do
      nil ->
        changeset

      modes when is_map(modes) and map_size(modes) == 0 ->
        changeset

      modes when is_map(modes) ->
        validate_each_mode(changeset, modes)

      _other ->
        add_error(changeset, :modes, "must be a map")
    end
  end

  defp validate_each_mode(changeset, modes) do
    Enum.reduce_while(modes, changeset, fn {name, mode}, cs ->
      case validate_mode_value(name, mode) do
        :ok -> {:cont, cs}
        {:error, msg} -> {:halt, add_error(cs, :modes, "#{name}: #{msg}")}
      end
    end)
  end

  defp validate_mode_value(_name, %{"caps" => caps}) do
    Nest.Sandbox.validate_caps(caps)
  end

  defp validate_mode_value(_name, _mode) do
    {:error, "mode must be a map with a \"caps\" key"}
  end
end
