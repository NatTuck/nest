defmodule Nest.Spaces.Creation do
  @moduledoc """
  Creating a space: the row on its own, and the row together with its root agent.

  Its own module because `Nest.Spaces` is at its file-length cap, and because
  these are the only paths that resolve a *vocation*: a space is created from a
  blueprint whose `root_vocation` names the root agent's role, and everything
  else in `Nest.Spaces` treats that as already decided.

  Both entry points are documented and delegated on `Nest.Spaces`, which is where
  callers look; nothing here is meant to be called directly. (The one exception
  is `broadcast_spaces_changed/1`, which lives there because the lifecycle
  actions — delete, archive, unarchive — announce through it too.)
  """

  alias Nest.Agents
  alias Nest.Blueprints
  alias Nest.Repo
  alias Nest.Spaces
  alias Nest.Spaces.CreationParams
  alias Nest.Spaces.Space
  alias Nest.Vocations

  # Documented on `Nest.Spaces.create_space/2`, the context's entry point.
  @doc false
  @spec create_space(integer(), map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def create_space(user_id, attrs) do
    with {:ok, %Space{} = space} <-
           %Space{}
           |> Space.create_changeset(CreationParams.for_create(attrs, user_id))
           |> Repo.insert() do
      # Announced here so `create_space/2` is self-contained: whoever creates a
      # space announces it, whatever they do next. When the caller is
      # `create_space_with_root_agent/2` this fires *inside* its transaction,
      # before the commit, so a channel that reconciles on it reads committed
      # state, does not see the new space, and is a no-op — and that wrapper
      # announces again after the commit, which is the frame that carries the
      # meaning for the lobby's create path. The duplicate is therefore
      # harmless: `reconcile_space_subscriptions/1` is an idempotent diff, so
      # running it twice costs one extra read and changes nothing.
      Spaces.broadcast_spaces_changed(user_id)
      {:ok, space}
    end
  end

  # Documented on `Nest.Spaces.create_space_with_root_agent/2`, the context's
  # entry point.
  @doc false
  @spec create_space_with_root_agent(integer(), map()) ::
          {:ok, Space.t(), String.t()} | {:error, term()}
  def create_space_with_root_agent(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, %Space{} = space} <- create_space_and_root_agent(user_id, attrs) do
        space
      end
    end)
    |> case do
      {:ok, {space, agent_name}} ->
        # The frame that matters for this path: `create_space/2` already
        # announced inside the transaction, but that one ran pre-commit, so a
        # reconciling channel could not see the new space yet. This is the
        # post-commit announcement the lobby's create path relies on.
        Spaces.broadcast_spaces_changed(user_id)
        {:ok, space, agent_name}

      {:error, reason} ->
        {:error, reason}

      other ->
        other
    end
  end

  defp create_space_and_root_agent(user_id, attrs) do
    # The root vocation is resolved and validated BEFORE the
    # space row is created. If we created the space first, a bad
    # `blueprint_id` would trip the `spaces.blueprint_id` FK
    # constraint on insert (a raw `Ecto.ConstraintError`) instead
    # of surfacing a clean `{:error, :blueprint_missing}`.
    with {:ok, root_vocation_id} <- resolve_root_vocation(attrs),
         :ok <- ensure_root_workspace(attrs),
         {:ok, %Space{} = space} <-
           create_space(
             user_id,
             Map.take(attrs, [
               :name,
               :slug,
               :blueprint_id,
               :workspace_path,
               :sandbox_backend,
               :network_access
             ])
           ),
         agent_opts = build_root_agent_opts(user_id, attrs, space, root_vocation_id),
         {:ok, agent_name} <- Agents.create_agent(space.id, attrs[:model], agent_opts) do
      {space, agent_name}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A space's workspace is a space property its agents inherit, and a space now
  # *requires* one — `Nest.Spaces.Space.create_changeset/2` is where that
  # invariant lives, so this is not the gate for it. What this adds, before the
  # row is built, is a refusal a user can act on:
  #
  #   * a missing path, which the changeset would also refuse but only as a
  #     generic `failed_to_create` — an `Ecto.Changeset` is not fit to show
  #     anyone, so the named reason `:workspace_required` is worth keeping here;
  #   * a path the sandbox cannot bind, which `Nest.Sandbox.workspace_error/1`
  #     names precisely (`:workspace_missing`, `:workspace_under_tmp`) and which
  #     `Nest.Sandbox.build/4` would refuse anyway — but only later, once the
  #     space existed and every command in it had already failed.
  #
  # No vocation lookup any more: every space has a workspace, so there is nothing
  # left to derive the requirement from.
  defp ensure_root_workspace(attrs) do
    case attrs[:workspace_path] do
      workspace when is_binary(workspace) and workspace != "" ->
        Nest.Sandbox.workspace_error(workspace)

      _absent ->
        {:error, :workspace_required}
    end
  end

  # Vocation resolution order:
  #
  #   1. Explicit `vocation:` slug in attrs (caller override).
  #   2. The blueprint's `root_vocation` slug (Phase 2 contract).
  #   3. Neither → `{:error, :missing_vocation}`. `create_space_with_root_agent`
  #      requires a vocation; `Agents.create_agent/3` does NOT
  #      fall back to the first available vocation (that fallback
  #      lives only in the lobby's `default_vocation_slug/0`).
  #
  # Returns `{:error, :blueprint_missing}` when `:blueprint_id`
  # is set but no row with that id exists — surfacing the error
  # rather than silently falling back to a default vocation.
  defp resolve_root_vocation(attrs) do
    case Map.get(attrs, :vocation) do
      slug when is_binary(slug) ->
        resolve_vocation_slug(slug)

      _ ->
        resolve_blueprint_vocation(Map.get(attrs, :blueprint_id))
    end
  end

  defp resolve_vocation_slug(slug) do
    case Vocations.get_by_slug(slug) do
      nil -> {:error, {:vocation_not_found, slug}}
      %Vocations.Vocation{id: id} -> {:ok, id}
    end
  end

  defp resolve_blueprint_vocation(nil), do: {:error, :missing_vocation}

  defp resolve_blueprint_vocation(bid) when is_integer(bid) do
    case Blueprints.root_vocation_slug_for(bid) do
      nil -> {:error, :blueprint_missing}
      slug -> resolve_vocation_slug(slug)
    end
  end

  defp build_root_agent_opts(user_id, attrs, space, root_vocation_id) do
    [
      name: root_agent_name(attrs, space),
      vocation_id: root_vocation_id,
      # No `:workspace_path`: a workspace is the space's, and the root agent
      # inherits it from the row this call just wrote
      # (`Nest.Persistence.start_attrs/7`).
      created_by_user_id: user_id,
      shared: Map.get(attrs, :shared, false)
    ]
  end

  # Root agent name. Falls back to the slug if the caller
  # doesn't supply an explicit name. The slug is guaranteed
  # non-nil because `create_space` derives it from `name`, and
  # `Space.changeset/2` guarantees the derived name is filename-safe
  # (`Space.root_agent_suffix/0` is the suffix it validates against).
  defp root_agent_name(attrs, %Space{slug: slug}) do
    attrs[:agent_name] || slug <> Space.root_agent_suffix()
  end
end
