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
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Sandbox
  alias Nest.Sandbox.Backend
  alias Nest.Spaces.Creation
  alias Nest.Spaces.Space

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

  # Announced by whoever changes the set: the lifecycle actions here, and the
  # creation paths in `Nest.Spaces.Creation`. Public for that second caller, and
  # not part of the context's API beyond it.
  @doc false
  @spec broadcast_spaces_changed(integer()) :: :ok | {:error, term()}
  def broadcast_spaces_changed(user_id) do
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
    |> backend_or_default()
  end

  # The one fallback for a missing/absent backend, shared with
  # `environment/1` so the two cannot disagree.
  defp backend_or_default(backend) when is_binary(backend), do: backend
  defp backend_or_default(_backend), do: Backend.default()

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
  `update_environment/2` rather than re-read here.
  """
  @spec network_access(integer()) :: boolean()
  def network_access(space_id) when is_integer(space_id) do
    from(s in Space, where: s.id == ^space_id, select: s.network_access)
    |> Repo.one()
    |> network_or_default()
  end

  # The one fallback for a missing/absent network value, shared with
  # `environment/1`.
  defp network_or_default(value) when is_boolean(value), do: value
  defp network_or_default(_value), do: true

  @doc """
  The three environment values of `space_id`, in **one** read.

  The start path needs all three together — an agent's `Nest.Sandbox.Mounts` is
  built from them — so asking the three readers above costs three round trips
  for one row. Each value falls back exactly as its own reader does, and the
  fallbacks are the same code, so the two paths cannot disagree: a missing row
  is `nil` for the workspace, `Backend.default/0` for the backend and `true` for
  the network.
  """
  @spec environment(integer()) :: %{
          workspace_path: String.t() | nil,
          network_access: boolean(),
          sandbox_backend: String.t()
        }
  def environment(space_id) when is_integer(space_id) do
    from(s in Space,
      where: s.id == ^space_id,
      select: {s.workspace_path, s.sandbox_backend, s.network_access}
    )
    |> Repo.one()
    |> case do
      {workspace, backend, network} ->
        %{
          workspace_path: workspace,
          sandbox_backend: backend_or_default(backend),
          network_access: network_or_default(network)
        }

      nil ->
        %{workspace_path: nil, sandbox_backend: Backend.default(), network_access: true}
    end
  end

  @doc """
  Edit this space's **environment**: its workspace, its network access and its
  sandbox backend.

  One action owns all three because they are one decision. Every agent in the
  space inherits them, and an agent's `Nest.Sandbox.Mounts` is built from them
  once at start — so the row is the truth, and the agents have to be told.

  Nothing is restarted. A live agent is cast the new values
  (`Nest.Agents.Agent.space_changed/2`): its mounts move, its tool closures are
  rebuilt from them, and it appends a notice pair stating the environment now in
  force. Its system prompt is deliberately **not** rebuilt — that would break the
  LLM prefix cache — which is why the notice exists.

  Any change to the three releases this space's sandbox environment, not only a
  backend change: all three are part of a container's identity (the image, the
  `--network` value and the workspace binds are fixed at creation), so a
  `"docker"` space's container is replaced by the next command whatever moved.
  `remove_sandbox/1` is therefore given the **old** backend, read before the row
  is written; reading it afterwards would release the new backend's containers
  and leak the old. Everything that lived only in the container — the agents'
  `/tmp` (offloads, background-job logs) and any running background job — goes
  with it, and the UI says so before the save.

  A save that names what the row already says is **not** an edit: nothing is
  released, nobody is told, and the row is not rewritten.

  Every agent in the space is marked with `space_notice_pending` and the live
  ones are also cast. The flag is cleared by whoever actually appends the notice:
  a live agent as it appends, or the agent's own start path. An agent that is
  mid-turn cannot take the notice — `Nest.Agents.Agent.WorkspaceHandler` says so
  with `{:ignored, phase}` — so it keeps the flag and announces the change at its
  next start. That is what keeps an edit from being silently dropped for the
  agents that are working at the time.

  Returns `{:ok, space}`, or `{:error, reason}` where `reason` is `:not_found`,
  the space changeset, or a workspace refusal from `Nest.Sandbox.workspace_error/1`
  — the same codes the create path produces, including the tagged
  `{:config_file_not_regular, path, type}`.
  """
  @spec update_environment(integer(), map()) ::
          {:ok, Space.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :workspace_missing
             | :workspace_under_tmp
             | {:config_file_not_regular, String.t(), atom()}}
  def update_environment(id, params) when is_integer(id) and is_map(params) do
    case get_space(id) do
      nil ->
        {:error, :not_found}

      %Space{sandbox_backend: old_backend} = space ->
        space
        |> Space.environment_changeset(params)
        |> apply_environment(old_backend)
    end
  end

  # A save that names what the row already says is not an edit: releasing the
  # container here would destroy a live environment for nothing, and telling the
  # agents would announce a change that did not happen.
  defp apply_environment(changeset, old_backend) do
    with :ok <- workspace_gate(changeset) do
      if changeset.changes == %{} do
        {:ok, changeset.data}
      else
        write_environment(changeset, old_backend)
      end
    end
  end

  defp write_environment(changeset, old_backend) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        # The *old* backend: the containers to release are the ones it made.
        remove_sandbox(%{updated | sandbox_backend: old_backend})
        announce_environment(updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # A workspace the sandbox cannot run is refused **here** rather than at the next
  # agent start: the edit is the moment the user can still pick another one, and
  # the reply codes are the ones the create path already produces.
  defp workspace_gate(changeset) do
    case Ecto.Changeset.get_change(changeset, :workspace_path) do
      nil -> :ok
      path -> Sandbox.workspace_error(path)
    end
  end

  # The space's environment, as the three values an agent's mounts carry.
  @doc false
  @spec environment_values(Space.t()) :: map()
  def environment_values(%Space{} = space) do
    %{
      workspace_path: space.workspace_path,
      network_access: space.network_access,
      sandbox_backend: space.sandbox_backend
    }
  end

  # Every agent in the space is owed the notice, and the flag is what records it
  # for an agent that cannot be told now.
  #
  # Mark *every* agent first, in one statement, then cast the live ones. A live
  # agent answers the cast by appending the pair and clearing its own flag, so it
  # ends up clear; a stopped agent, and a **mid-turn** one — the cast cannot
  # deliver the notice to a machine that is `:generating` or `:executing_tools`
  # (`Nest.Agents.Agent.WorkspaceHandler`) — keeps the flag and announces the
  # change at its next start.
  #
  # Marking every agent rather than only the ones with no process is what makes
  # the mid-turn case recoverable at all: an agent that is *cast* cannot be
  # excluded from the mark, because the cast is a request it may refuse.
  #
  # ## The one window this does not close
  #
  # The mark and the clear are both plain writes to one boolean, so an edit that
  # lands *inside* an agent's start can still be erased: the start path reads the
  # flag from its attrs snapshot, appends its notice and then writes `false`
  # unconditionally. If edit 1 marked the agent before that snapshot (so the start
  # has a notice to append) and edit 2 marks it after the snapshot but before the
  # clear, edit 2's mark is overwritten — and if edit 2's cast is then refused
  # because the agent is busy, edit 2's notice is lost until a later edit.
  #
  # Closing it needs a compare-and-set, which needs a mark stamp on the row (a
  # migration) — more machinery than a window this narrow justifies: it takes two
  # edits and a start interleaved to the message, and the agent still announces
  # the *first* edit's values. It is recorded here rather than implied away: the
  # duplicate pair below is the harmless half of the trade, this is the half that
  # is a loss.
  #
  # The harmless half: an agent that starts inside the window announces at start
  # and then finds the cast in its mailbox, so it appends the pair twice. The pair
  # reconciles the values now in force, so a duplicate is not misleading.
  defp announce_environment(%Space{id: id} = space) do
    mark_notice_pending(id)
    tell_agents(space)
  end

  defp mark_notice_pending(id) do
    from(a in PersistedAgent, where: a.space_id == ^id)
    |> Repo.update_all(set: [space_notice_pending: true])

    :ok
  end

  # Hand the space's new environment to every live agent in it. The values travel
  # on an agent's `Nest.Sandbox.Mounts`, which is what its caps are resolved from
  # and what its tool closures were built with, so an agent that started before
  # the change would otherwise keep the old values for the rest of its life —
  # this is the only thing that closes that window short of a restart.
  #
  # A cast, not a call: the values are the *space's*, so there is nothing an agent
  # could refuse, and an edit must not wait on a turn. A name in the registry with
  # no live process behind it is skipped; that agent's `space_notice_pending` flag
  # is what tells it on its next start.
  defp tell_agents(%Space{id: id} = space) do
    values = environment_values(space)

    id
    |> Agents.Registry.list_for_space()
    |> Enum.each(fn name ->
      case Agents.Registry.lookup(id, name) do
        {:ok, pid} -> Agents.Agent.space_changed(pid, values)
        {:error, :not_found} -> :ok
      end
    end)
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
    `:slug`, `:blueprint_id`, `:workspace_path`, `:network_access`,
    `:sandbox_backend`

  ## Returns

  * `{:ok, %Space{}}` on success
  * `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_space(integer(), map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_space(user_id, attrs), to: Creation

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
  # a space release its containers, and so does an edit to its environment. All
  # three of the environment's properties are part of a container's identity —
  # the image, the `--network` value and the workspace binds are fixed when it is
  # created — so any edit leaves a container the next command must not reuse.
  defp remove_sandbox(%Space{id: id, sandbox_backend: backend}) do
    Backend.remove_space(id, backend)
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
  defdelegate create_space_with_root_agent(user_id, attrs), to: Creation
end
