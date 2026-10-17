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
  alias Nest.Sandbox.Backend
  alias Nest.Spaces.CreationParams
  alias Nest.Spaces.Space
  alias Nest.Vocations

  # The per-user PubSub topic: "this user's space *set* changed" (a space
  # was created/archived/unarchived/deleted — and, once space sharing
  # lands, a membership change). `NestWeb.LobbyChannel` listens here to
  # keep its space subscriptions in step with the change, whichever of the
  # user's sessions made it (including the one that did: a PubSub
  # subscription is delivered to `handle_info/2`, not routed through the
  # channel's `handle_out/3` the way a `broadcast/3` on the channel's own
  # topic would be).
  @spec user_topic(integer()) :: String.t()
  def user_topic(user_id), do: "user:#{user_id}"

  defp broadcast_spaces_changed(user_id) do
    Phoenix.PubSub.broadcast(Nest.PubSub, user_topic(user_id), {:spaces_changed, user_id})
  end

  @doc """
  List all non-archived spaces visible to the given user.

  A user sees every space they created (`created_by_user_id
  == user.id`). Multi-participant sharing is deferred.

  Archived spaces are excluded here so nothing about them is
  loaded into the main space list; inspect those via
  `list_archived_for_user/1`.
  """
  @spec list_for_user(integer()) :: [Space.t()]
  def list_for_user(user_id) do
    from(s in Space,
      where: s.created_by_user_id == ^user_id,
      where: s.archived == false,
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  List all archived spaces visible to the given user.

  Owner-only: a user sees the archived spaces they created.
  This is the query behind the archived-spaces list view.
  """
  @spec list_archived_for_user(integer()) :: [Space.t()]
  def list_archived_for_user(user_id) do
    from(s in Space,
      where: s.created_by_user_id == ^user_id,
      where: s.archived == true,
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
  Get a space by its globally-unique name.

  Returns `%Space{}` or `nil`.
  """
  @spec get_by_name(String.t()) :: Space.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(Space, name: name)
  end

  @doc """
  The workspace path of `space_id`.

  The workspace is a **space** property: every agent in the space binds the
  same directory, and an agent's value comes from here at start (through
  `Nest.Persistence.start_attrs/7`, which puts it on the attrs so
  `Nest.Agents.Agent.Init` never reads the DB). There is no per-agent
  workspace — `agents.workspace_path` is gone.

  A missing row resolves to `nil`, which is the "no workspace" value every
  consumer already handles; the caller's agent is about to fail for a better
  reason than "no such space".
  """
  @spec workspace_path(integer()) :: String.t() | nil
  def workspace_path(space_id) when is_integer(space_id) do
    from(s in Space, where: s.id == ^space_id, select: s.workspace_path)
    |> Repo.one()
  end

  @doc """
  The sandbox backend of `space_id`: one of `Backend.backends/0`.

  Resolved from the space row rather than stored per agent, because the
  backend is a space property: every agent in a space shares one
  environment. A missing row resolves to `Backend.default/0`
  — the caller's agent is about to fail for a better reason than "unknown
  backend", and defaulting keeps this a total function.

  Read once, at agent start, and carried on the agent's
  `Nest.Sandbox.Mounts` value from then on, so no tool call needs a DB read
  (see `Nest.Sandbox.Backend`).
  """
  @spec sandbox_backend(integer()) :: String.t()
  def sandbox_backend(space_id) when is_integer(space_id) do
    from(s in Space, where: s.id == ^space_id, select: s.sandbox_backend)
    |> Repo.one()
    |> case do
      backend when is_binary(backend) -> backend
      _ -> Backend.default()
    end
  end

  @doc """
  The network access of `space_id`.

  Resolved from the space row rather than from a vocation mode, because the
  network is a space property. A missing row resolves to `true`, which is the
  column's default: the caller is about to fail for a better reason than a
  missing space, and defaulting keeps this total. (A value that names *no* space
  — a tool call with no space behind it — keeps `Nest.Sandbox.default_caps/0`'s
  `net: false` instead; see `Nest.Sandbox.with_network_access/2`.)

  Read once, at agent start, and carried on the agent's
  `Nest.Sandbox.Mounts` value from then on, so caps resolution never reads the
  DB. A change to the column is pushed to the space's live agents by
  `set_network_access/2` rather than re-read here.
  """
  @spec network_access(integer()) :: boolean()
  def network_access(space_id) when is_integer(space_id) do
    from(s in Space, where: s.id == ^space_id, select: s.network_access)
    |> Repo.one()
    |> case do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  @doc """
  Turn this space's network access on or off.

  Editable, unlike `sandbox_backend`: a space can be closed off or opened up
  without recreating it. Every live agent in the space is told as part of the
  change, so the *next* command it runs already resolves its caps with the new
  value; a command already in flight keeps the caps it started with.

  A `"docker"` space's container is removed as part of the change, because
  `--network none` is fixed when the container is created: without that, the next
  command would keep using the container's old network. The container is
  recreated lazily by that next command, and everything that lived only in it —
  the agents' `/tmp` (offloads, background-job logs) and any running background
  job — goes with it. The UI says so before the toggle is flipped. For a
  `"none"` space nothing is released: the caps were never enforceable there, and
  the toggle has always been advisory.

  Returns `{:ok, space}` or `{:error, reason}`.
  """
  @spec set_network_access(integer(), boolean()) ::
          {:ok, Space.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_network_access(id, value) when is_integer(id) and is_boolean(value) do
    case get_space(id) do
      nil ->
        {:error, :not_found}

      %Space{} = space ->
        case space |> Space.changeset(%{network_access: value}) |> Repo.update() do
          {:ok, updated} ->
            remove_sandbox(updated)
            tell_agents(updated, value)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  The ids of every space whose backend is `"none"`.

  Two `"none"` spaces share the host's real `/tmp` (an agent's scratch dir
  there is `/tmp/<agent-name>`), so their agent names form one shared
  namespace. The name boundary uses this to find the *other* `"none"`
  spaces to check a requested name against — see
  `Nest.Agents.Supervisor.existing_names_for_space/1` and
  `Nest.Agents.Agent.PreSpawn.pre_spawn/1`.
  """
  @spec none_space_ids() :: MapSet.t(integer())
  def none_space_ids do
    from(s in Space, where: s.sandbox_backend == "none", select: s.id)
    |> Repo.all()
    |> MapSet.new()
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
    `:slug`, `:blueprint_id`, `:sandbox_backend`

  ## Returns

  * `{:ok, %Space{}}` on success
  * `{:error, %Ecto.Changeset{}}` on validation failure
  """
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
      broadcast_spaces_changed(user_id)
      {:ok, space}
    end
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

        # The space is gone, so whatever its backend kept alive outside the BEAM
        # goes with it (a `"docker"` space's containers). After the rows, so a
        # failure here cannot leave a space without its agents' rows.
        remove_sandbox(space)

        # The space is gone, so it can no longer be in anyone's visible set:
        # tell the owner's channels to drop their subscription to its topic.
        broadcast_spaces_changed(space.created_by_user_id)

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

  @doc """
  Archive a space, hiding it from the main space list.

  Stops every live agent in the space (via `stop_space_agents/1`,
  which cascade-walks `ChildRegistry` for descendants) and marks
  the space row archived. Agent rows are NOT marked archived —
  they remain intact so unarchiving restores the space cleanly,
  and agents are rehydrated on demand when the space is reopened.

  The archived space remains inspectable via
  `list_archived_for_user/1` and reversible via `unarchive_space/1`.

  Returns `:ok` on success, `{:error, :not_found}` if the space
  doesn't exist.
  """
  @spec archive_space(integer()) :: :ok | {:error, :not_found}
  def archive_space(id) when is_integer(id) do
    case Repo.get(Space, id) do
      nil ->
        {:error, :not_found}

      space ->
        stop_space_agents(space.id)

        # An archived space is out of service, so its backend's environment goes
        # too — a `"docker"` space's containers. Unarchiving recreates them
        # lazily, which is why this is safe here and not only on delete.
        remove_sandbox(space)

        set_archived(space.id, true)
        broadcast_spaces_changed(space.created_by_user_id)
    end
  end

  @doc """
  Restore an archived space to the main space list.

  Flips the `archived` flag back to `false`. Agents are not
  eagerly restarted — they're rehydrated on demand by
  `Supervisor.get_agent/2` when the user next opens the space.

  Returns `:ok` on success, `{:error, :not_found}` if the space
  doesn't exist.
  """
  @spec unarchive_space(integer()) :: :ok | {:error, :not_found}
  def unarchive_space(id) when is_integer(id) do
    case Repo.get(Space, id) do
      nil ->
        {:error, :not_found}

      space ->
        set_archived(space.id, false)
        broadcast_spaces_changed(space.created_by_user_id)
    end
  end

  # Release whatever the space's backend keeps alive outside the BEAM. The
  # backend is passed from the row rather than looked up in the sandbox layer,
  # which must not read this schema (see `Nest.Sandbox.Mounts`); every backend
  # but docker is a no-op, and a failure is logged by that layer, not raised.
  #
  # Three callers, and the third is not a lifecycle event: archiving and deleting
  # a space release its containers, and so does a change to the space's network
  # access, because a container's network is fixed at creation and the next
  # command has to build one with the new value.
  defp remove_sandbox(%Space{id: id, sandbox_backend: backend}) do
    Backend.remove_space(id, backend)
  end

  # Hand the space's new network access to every live agent in it. The value
  # travels on an agent's `Nest.Sandbox.Mounts`, which is what its caps are
  # resolved from and what its tool closures were built with, so an agent that
  # started before the change would otherwise keep the old value for the rest of
  # its life — this is the only thing that closes that window short of a restart.
  #
  # A cast, not a call: the value is the *space's*, so there is nothing an agent
  # could refuse, and an edit to a space must not wait on a turn. Nothing is
  # reported back either — a name in the registry with no live process behind it
  # is skipped, which the registry already guarantees but the lookup is what makes
  # true rather than assumed.
  defp tell_agents(%Space{id: id}, value) do
    id
    |> Agents.Registry.list_for_space()
    |> Enum.each(fn name ->
      case Agents.Registry.lookup(id, name) do
        {:ok, pid} -> Agents.Agent.set_network_access(pid, value)
        {:error, :not_found} -> :ok
      end
    end)
  end

  defp set_archived(id, archived) do
    from(s in Space, where: s.id == ^id)
    |> Repo.update_all(set: [archived: archived, updated_at: Persistence.now()])

    :ok
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
  blueprint is missing) — meaning `agents-spawn` allows any
  vocation. Otherwise returns the blueprint's
  `spawnable_vocations` slug list (an empty list also means
  unrestricted; a non-empty list is a strict whitelist).

  `agents-spawn` enforcement lives in
  `Nest.Agents.Supervisor.spawn_agent_in_space/3`, which calls
  this to authorize a requested vocation slug.
  """
  @spec spawnable_vocations_for_space(integer()) :: [String.t()] | nil
  def spawnable_vocations_for_space(space_id) when is_integer(space_id) do
    case get_space(space_id) do
      %Space{blueprint_id: nil} -> nil
      %Space{blueprint_id: bid} -> Blueprints.spawnable_vocations(bid)
      _ -> nil
    end
  end

  @doc """
  Resolve the blueprint's default spawn vocation for a space.

  Returns `nil` when the space has no blueprint, the blueprint is gone, **or**
  the blueprint has no default. The three cases are deliberately one answer,
  because `agents-spawn` treats them identically: an omitted `vocation` is
  refused with an error naming the missing argument rather than falling back to
  the caller's own vocation.

  `Nest.Agents.Supervisor.resolve_spawn_vocation/2` is the caller.
  """
  @spec default_spawnable_vocation_for_space(integer()) :: String.t() | nil
  def default_spawnable_vocation_for_space(space_id) when is_integer(space_id) do
    case get_space(space_id) do
      %Space{blueprint_id: nil} -> nil
      %Space{blueprint_id: bid} -> Blueprints.default_spawnable_vocation(bid)
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
      `root_vocation` slug unless `:vocation` is also
      supplied (the explicit `:vocation` wins).
    * `:model` — root agent's model map (required; same shape
      as `Agents.create_agent/3`'s `model` arg)
    * `:vocation` — root agent's vocation **slug** (optional;
      derived from blueprint when omitted)
    * `:workspace_path` — the space's workspace path (**required**;
      refused by name when it is missing, is not a directory, or is at
      or under the sandbox scratch root)
    * `:sandbox_backend` — optional space sandbox backend
      (defaults to `Backend.default/0`)
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
      {:ok, {space, agent_name}} ->
        # The frame that matters for this path: `create_space/2` already
        # announced inside the transaction, but that one ran pre-commit, so a
        # reconciling channel could not see the new space yet. This is the
        # post-commit announcement the lobby's create path relies on.
        broadcast_spaces_changed(user_id)
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
