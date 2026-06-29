defmodule Nest.Agents.PersistedAgent do
  @moduledoc """
  Ecto schema for the `agents` table. One row per agent, keyed
  by the human-readable id (e.g. `"clever-raven"`).

  The schema is the persistence-side mirror of the runtime
  `Nest.Agents.Agent` struct's identity fields (`id`, `vocation`,
  `model`, `workspace_path`, `next_message_index`). The full
  runtime state (tools, llm_metrics, chat_state, etc.) lives only
  in memory; the row is just enough to rehydrate the agent on
  restore.

  `vocation` is loaded from the DB at restore time via
  `Persistence.load_vocation/1` (the in-memory `Agent` carries the
  struct; the row carries the id only).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t(),
          vocation_id: integer() | nil,
          model: map(),
          workspace_path: String.t() | nil,
          next_message_index: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "agents" do
    field :vocation_id, :integer
    field :model, :map
    field :workspace_path, :string
    field :next_message_index, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a changeset for upserting an agent row.

  Required: `:id` and `:model`. `:vocation_id` and `:workspace_path`
  are optional. `:next_message_index` defaults to 0 and is
  bumped on every persisted message via a separate UPDATE.

  Accepts both atom-keyed and string-keyed params (callers
  from the test suite pass string keys; the Agent's runtime
  uses atom keys). String keys are normalized to atoms here.
  """
  def changeset(source, params) do
    params = atomize_keys(params)

    source
    |> cast(params, [:id, :vocation_id, :model, :workspace_path, :next_message_index])
    |> validate_required([:id, :model])
    |> validate_length(:id, min: 1)
  end

  defp atomize_keys(params) when is_map(params) and not is_struct(params) do
    Map.new(params, fn {k, v} -> {if(is_binary(k), do: safe_atom(k), else: k), v} end)
  end

  defp atomize_keys(other), do: other

  # Convert a string key to an atom, falling back to the
  # original string if the atom doesn't exist (e.g. for
  # unknown keys from a future caller).
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
