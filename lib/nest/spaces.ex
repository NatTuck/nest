defmodule Nest.Spaces do
  @moduledoc """
  Context for space CRUD operations.

  Spaces are containers for groups of collaborating agents.
  Every agent belongs to exactly one space. There is no
  synthetic default space — every `space_id` is a real
  `Space.id` allocated by the application, and no space is
  auto-created on connect. A user starts with no spaces and
  creates one explicitly via `create_space_with_root_agent/2`.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents
  alias Nest.Agents.NameGenerator
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Spaces.Space
  alias Nest.Vocations

  @doc """
  List all spaces visible to the given user.

  A user sees every space they created (`created_by_user_id
  == user.id`). Multi-participant sharing is deferred.
  """
  @spec list_for_user(integer()) :: [Space.t()]
  def list_for_user(user_id) do
    from(s in Space,
      where: s.created_by_user_id == ^user_id,
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Suggest a unique, readable space name (adjective-animal format,
  e.g. "clever-raven").

  Space names are globally unique, so the suggestion is generated
  against the set of *all* space names, not just the current user's.
  The new-space form pre-fills this so a user can create a space
  without typing a name, without colliding with an existing one.
  """
  @spec suggest_name() :: String.t()
  def suggest_name do
    existing = Repo.all(from(s in Space, select: s.name))
    NameGenerator.generate_unique(MapSet.new(existing))
  end

  @doc """
  Get a space by its slug.

  Returns `%Space{}` or `nil`.
  """
  @spec get_by_slug(String.t()) :: Space.t() | nil
  def get_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Space, slug: slug)
  end

  @doc """
  Get a space by its ID.

  Returns `%Space{}` or `nil`.
  """
  @spec get_space(integer()) :: Space.t() | nil
  def get_space(id) when is_integer(id) do
    Repo.get(Space, id)
  end

  @doc """
  Create a new space for the given user.

  ## Parameters

  * `user_id` — the user creating the space
  * `attrs` — map with `:name` (required) and optionally
    `:slug`, `:blueprint_id`

  ## Returns

  * `{:ok, %Space{}}` on success
  * `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_space(integer(), map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def create_space(user_id, attrs) do
    %Space{}
    |> Space.changeset(Map.put(attrs, :created_by_user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Delete a space by ID, cascading to its agents.

  Terminates every running agent in the space (the existing
  `Supervisor.stop_agent/2` cascade handles descendants via
  `ChildRegistry`), then deletes all agent rows and the space
  row in a single transaction.

  The processes are terminated *before* the DB transaction so
  no live agent can fire a DB write (message append, model
  update) into the rows we're about to delete.

  Returns `:ok` on success, `{:error, :not_found}` if the
  space doesn't exist.
  """
  @spec delete_space(integer()) :: :ok | {:error, :not_found}
  def delete_space(id) do
    case Repo.get(Space, id) do
      nil ->
        {:error, :not_found}

      space ->
        stop_space_agents(space.id)

        Repo.transaction(fn ->
          delete_agent_rows(space.id)
          Repo.delete!(space)
        end)

        :ok
    end
  end

  @doc """
  Rename a space in place.

  `Space.changeset` re-derives the `slug` from the new `name`
  when one isn't supplied; both `name` and `slug` are globally
  unique, so a collision surfaces as a changeset error.

  Renaming a space does not touch its agents — PubSub topics
  and Registry keys are keyed off `space_id` (unchanged), not
  the slug. (A changed slug does affect `/space/:slug` routes,
  but those are a Phase 4 frontend concern.)

  Returns `{:ok, %Space{}}` on success,
  `{:error, %Ecto.Changeset{}}` on a validation/unique failure,
  or `{:error, :not_found}` if the space doesn't exist.
  """
  @spec rename_space(integer(), map()) ::
          {:ok, Space.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def rename_space(id, attrs) when is_integer(id) and is_map(attrs) do
    case Repo.get(Space, id) do
      nil ->
        {:error, :not_found}

      space ->
        space
        |> Space.changeset(attrs)
        |> Repo.update()
    end
  end

  # Terminate every live agent in the space. `stop_agent/2`
  # cascade-walks `ChildRegistry` for descendants, so stopping
  # each row's name covers the whole tree; `:not_found` is
  # ignored for agents with no live process.
  defp stop_space_agents(space_id) do
    space_id
    |> Persistence.fetch_all_agents_for_space()
    |> Enum.each(fn %{name: name} ->
      _ = Supervisor.stop_agent(space_id, name)
    end)
  end

  defp delete_agent_rows(space_id) do
    space_id
    |> Persistence.fetch_all_agents_for_space()
    |> Enum.each(fn %{name: name} ->
      _ = Persistence.delete_agent(space_id, name)
    end)
  end

  @doc """
  Resolve the spawnable-vocation whitelist for a space.

  Returns `nil` when the space has no blueprint (or the
  blueprint is missing) — meaning `agents/spawn` allows any
  vocation. Otherwise returns the blueprint's
  `spawnable_vocation_ids` (an empty list also means
  unrestricted; a non-empty list is a strict whitelist).

  `agents/spawn` enforcement lives in
  `Nest.Agents.Supervisor.spawn_agent_in_space/3`, which calls
  this to authorize a requested `vocation_id`.
  """
  @spec spawnable_vocation_ids_for_space(integer()) :: [integer()] | nil
  def spawnable_vocation_ids_for_space(space_id) when is_integer(space_id) do
    case get_space(space_id) do
      %Space{blueprint_id: nil} -> nil
      %Space{blueprint_id: bid} -> Blueprints.spawnable_vocation_ids(bid)
      _ -> nil
    end
  end

  @doc """
  Create a space and its root agent in a single transaction.

  ## Parameters

  * `user_id` — the user creating the space
  * `attrs` — space + root agent attributes:
    * `:name` — space name (required)
    * `:slug` — URL-safe identifier (optional; derived from `:name`)
    * `:blueprint_id` — optional FK. When supplied, the
      root agent's vocation is pulled from the blueprint's
      `root_vocation_id` unless `:vocation_id` is also
      supplied (the explicit `:vocation_id` wins).
    * `:model` — root agent's model map (required; same shape
      as `Agents.create_agent/3`'s `model` arg)
    * `:vocation_id` — root agent's vocation id (optional;
      derived from blueprint when omitted)
    * `:workspace_path` — optional root agent workspace path
    * `:agent_name` — root agent's name (optional; defaults
      to `"<slug>-root"`)

  ## Returns

  * `{:ok, %Space{}, root_agent_name}` on success
  * `{:error, term()}` on failure. The transaction is rolled
    back so the `agents` row never escapes without a space.
    `{:error, :blueprint_missing}` when `:blueprint_id` is
    set but no row with that id exists.
  """
  @spec create_space_with_root_agent(integer(), map()) ::
          {:ok, Space.t(), String.t()} | {:error, term()}
  def create_space_with_root_agent(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, %Space{} = space} <- create_space_and_root_agent(user_id, attrs) do
        space
      end
    end)
    |> case do
      {:ok, {space, agent_name}} -> {:ok, space, agent_name}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  defp create_space_and_root_agent(user_id, attrs) do
    # The root vocation is resolved and validated BEFORE the
    # space row is created. If we created the space first, a bad
    # `blueprint_id` would trip the `spaces.blueprint_id` FK
    # constraint on insert (a raw `Ecto.ConstraintError`) instead
    # of surfacing a clean `{:error, :blueprint_missing}`.
    with {:ok, root_vocation_id} <- resolve_root_vocation(attrs),
         :ok <- ensure_root_workspace(attrs, root_vocation_id),
         {:ok, %Space{} = space} <-
           create_space(user_id, Map.take(attrs, [:name, :slug, :blueprint_id, :workspace_path])),
         agent_opts = build_root_agent_opts(user_id, attrs, space, root_vocation_id),
         {:ok, agent_name} <- Agents.create_agent(space.id, attrs[:model], agent_opts) do
      {space, agent_name}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The workspace is a space property that agents inherit. When the
  # resolved root vocation's agents expect a workspace (their caps
  # write to `":workspace"`), the space must be given one up front —
  # otherwise the root agent would start with a nil workspace and its
  # file/shell tools would fail at runtime. Reject the creation
  # immediately instead.
  defp ensure_root_workspace(attrs, root_vocation_id) do
    case Vocations.get_vocation(root_vocation_id) do
      nil -> :ok
      vocation -> ensure_workspace_for(vocation, attrs)
    end
  end

  defp ensure_workspace_for(%Nest.Vocations.Vocation{} = vocation, attrs) do
    if Vocations.requires_workspace?(vocation) and is_nil(attrs[:workspace_path]) do
      {:error, :workspace_required}
    else
      :ok
    end
  end

  defp ensure_workspace_for(_vocation, _attrs), do: :ok

  # Vocation resolution order:
  #
  #   1. Explicit `vocation_id:` in attrs (caller override).
  #   2. The blueprint's `root_vocation_id` (Phase 2 contract).
  #   3. Neither → `{:error, :missing_vocation}`. `create_space_with_root_agent`
  #      requires a vocation; `Agents.create_agent/3` does NOT
  #      fall back to the first available vocation (that fallback
  #      lives only in the lobby's `default_vocation_id/0`).
  #
  # Returns `{:error, :blueprint_missing}` when `:blueprint_id`
  # is set but no row with that id exists — surfacing the error
  # rather than silently falling back to a default vocation.
  defp resolve_root_vocation(attrs) do
    case Map.get(attrs, :vocation_id) do
      vid when is_integer(vid) ->
        {:ok, vid}

      _ ->
        resolve_blueprint_vocation(Map.get(attrs, :blueprint_id))
    end
  end

  defp resolve_blueprint_vocation(nil), do: {:error, :missing_vocation}

  defp resolve_blueprint_vocation(bid) when is_integer(bid) do
    case Blueprints.root_vocation_id_for(bid) do
      nil -> {:error, :blueprint_missing}
      vid -> {:ok, vid}
    end
  end

  defp build_root_agent_opts(user_id, attrs, space, root_vocation_id) do
    [
      name: root_agent_name(attrs, space),
      vocation_id: root_vocation_id,
      # The workspace is a space property; the root agent inherits
      # the space's path (an explicit override in `attrs` still wins).
      workspace_path: attrs[:workspace_path] || space.workspace_path,
      created_by_user_id: user_id,
      shared: Map.get(attrs, :shared, false)
    ]
  end

  # Root agent name. Falls back to the slug if the caller
  # doesn't supply an explicit name. The slug is guaranteed
  # non-nil because `create_space` derives it from `name`.
  defp root_agent_name(attrs, %Space{slug: slug}) do
    attrs[:agent_name] || "#{slug}-root"
  end
end
