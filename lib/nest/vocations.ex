defmodule Nest.Vocations do
  @moduledoc """
  The Nest.Vocations context.
  """

  import Ecto.Query, warn: false

  alias Nest.Repo

  alias Nest.Vocations.Vocation

  @doc """
  Returns the list of vocations.

  ## Examples

      iex> list_vocations()
      [%Vocation{}, ...]

  """
  def list_vocations do
    Repo.all(Vocation)
  end

  @doc """
  Gets a single vocation.

  Raises `Ecto.NoResultsError` if the Vocation does not exist.

  ## Examples

      iex> get_vocation!(123)
      %Vocation{}

      iex> get_vocation!(456)
      ** (Ecto.NoResultsError)

  """
  def get_vocation!(id), do: Repo.get!(Vocation, id)

  @doc """
  Gets a single vocation.

  Returns `nil` if the Vocation does not exist.

  ## Examples

      iex> get_vocation(123)
      %Vocation{}

      iex> get_vocation(456)
      nil

  """
  def get_vocation(id), do: Repo.get(Vocation, id)

  @doc """
  Gets a single vocation by its globally-unique slug.

  Returns `nil` if the Vocation does not exist.
  """
  @spec get_by_slug(String.t()) :: Vocation.t() | nil
  def get_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Vocation, slug: slug)
  end

  @doc """
  Creates a vocation.

  ## Examples

      iex> create_vocation(%{field: value})
      {:ok, %Vocation{}}

      iex> create_vocation(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_vocation(attrs) do
    %Vocation{}
    |> Vocation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a vocation.

  ## Examples

      iex> update_vocation(vocation, %{field: new_value})
      {:ok, %Vocation{}}

      iex> update_vocation(vocation, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_vocation(%Vocation{} = vocation, attrs) do
    vocation
    |> Vocation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a vocation.

  ## Examples

      iex> delete_vocation(vocation)
      {:ok, %Vocation{}}

      iex> delete_vocation(vocation)
      {:error, %Ecto.Changeset{}}

  """
  def delete_vocation(%Vocation{} = vocation) do
    Repo.delete(vocation)
  rescue
    Ecto.ConstraintError -> {:error, :agents_using_vocation}
  end

  @doc """
  Insert-or-update a vocation by its derived `slug`.

  A true Postgres upsert (`INSERT ... ON CONFLICT (slug) DO UPDATE`),
  so concurrent callers (seeds, parallel tests) can't deadlock on a
  select-then-insert race. `id` is preserved across a re-upsert, so FK
  references like `agents.vocation_id` stay valid.

  Used by `priv/repo/seeds.exs` so re-running seeds updates the
  existing rows (system prompts, tools) in place rather than
  failing or creating a second row.
  """
  @spec upsert_vocation(map()) :: {:ok, Vocation.t()} | {:error, Ecto.Changeset.t()}
  def upsert_vocation(attrs) when is_map(attrs) do
    %Vocation{}
    |> Vocation.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :description, :system_prompt, :tools, :updated_at]},
      conflict_target: :slug,
      returning: true
    )
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking vocation changes.

  ## Examples

      iex> change_vocation(vocation)
      %Ecto.Changeset{data: %Vocation{}}

  """
  def change_vocation(%Vocation{} = vocation, attrs \\ %{}) do
    Vocation.changeset(vocation, attrs)
  end

  @doc """
  Canonical description text for the `compact` mode as it appears in the agent's
  `[Available modes]` list. Single source of truth — the mode-catalog render
  reads from this function. The per-call `[mode: compact]` suffix (rendered by
  `Nest.Scripts.CompactionProbeSupport.compaction_suffix/2`) is intentionally a
  different shape: it's a protocol marker carrying the dynamic token-budget hint,
  not the prose guidance.

  It lives here rather than in `Nest.Modes` because the modes section is rendered
  next to it by `Nest.Agents.Agent.SystemPrompt`, and `Nest.Modes` deliberately
  knows nothing about the schema.
  """
  @spec compact_description() :: String.t()
  def compact_description do
    "We are out of context and it's time to generate a concise summary " <>
      "that fits in the remaining context that we can use to replace the " <>
      "existing conversation moving forward. Include incomplete tasks, " <>
      "decisions made, essential file paths, the user's current goal, " <>
      "key facts established, and any unresolved TODOs. Drop redundant " <>
      "tool outputs and resolved sub-tasks. Be brief but comprehensive " <>
      "enough that the conversation can continue from the summary alone."
  end
end
