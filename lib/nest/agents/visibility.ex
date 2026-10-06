defmodule Nest.Agents.Visibility do
  @moduledoc """
  Per-user agent visibility helpers used by the lobby.

  A user sees two classes of agent in `space_id`:

    * their own private agents (`created_by_user_id == user.id`
      and `shared == false`)
    * every shared agent (`shared == true`)

  Agents are uniquely identified by `{space_id, name}`.
  Both running (Registry-resident) and persisted (DB-row)
  agents are returned. The persisted branch keeps the lobby
  honest when the supervisor has no live pid for an agent
  whose row exists in `agents` (e.g. between boot and the
  first chat).

  Multi-participant sharing outside the
  owner/shared dichotomy is deferred.

  `list_non_archived_agents_for_space/1` is the no-user-filter
  variant: it returns every non-archived agent in a space
  (running or persisted-only) with no owner/shared predicate.
  The `agents-list` tool uses it, since a tool call carries no
  user identity and delegation targets are space-scoped.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.Agent
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Registry
  alias Nest.Repo
  alias Nest.Vocations

  @doc """
  Public-info map for every agent in `space_id` the
  given user is allowed to see. Returns a list of maps
  with `space_id`, `name`, and the rest of the public
  info.
  """
  @spec list_visible_agents_for(integer(), integer()) :: [map()]
  def list_visible_agents_for(space_id, user_id)
      when is_integer(space_id) and is_integer(user_id) do
    list_agents(space_id, user_id)
  end

  @doc """
  Public-info map for every non-archived agent in `space_id`,
  running or persisted-only, with no per-user filter. Archived
  agents are excluded; agents are de-duplicated by name so a
  running agent (registry entry plus its DB row) appears once.
  The merged list is ordered by name (not by which branch an
  agent came from), so the `agents-list` tool's 4000-char
  truncation drops the alphabetically-last agents.
  """
  @spec list_non_archived_agents_for_space(integer()) :: [map()]
  def list_non_archived_agents_for_space(space_id) when is_integer(space_id) do
    list_agents(space_id, nil)
  end

  defp list_agents(space_id, user_id) do
    space_id
    |> Registry.list_for_space()
    |> Enum.map(&fetch_from_registry(space_id, &1, user_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(persisted_visible(space_id, user_id))
    # The live (registry) branch is concatenated first so a running
    # agent's real status wins the de-dupe against its persisted row.
    # Sorting after that makes the merged order depend only on the
    # names — the truncation tail is then the alphabetically-last
    # agents rather than "whichever branch the agent came from".
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Public-info map for every *archived* agent in `space_id` the
  given user is allowed to see, in the same wire shape as
  `list_visible_agents_for/2` (plus `archived: true`). Archived
  agents have no live pid (archiving stops the process), so this
  is a persisted-rows-only read. `parent_name` is resolved from
  the parent row (which may itself still be active) so the
  sidebar can nest an archived subtree exactly as it was before
  archival.
  """
  @spec list_archived_agents_for(integer(), integer()) :: [map()]
  def list_archived_agents_for(space_id, user_id)
      when is_integer(space_id) and is_integer(user_id) do
    names_by_id = agent_names_by_id(space_id)

    from(a in PersistedAgent,
      where: a.space_id == ^space_id,
      where: a.created_by_user_id == ^user_id or a.shared == true,
      where: a.archived == true,
      order_by: a.name
    )
    |> Repo.all()
    |> Enum.map(&archived_public_info(&1, names_by_id))
  end

  defp archived_public_info(
         %PersistedAgent{
           name: name,
           space_id: sid,
           created_by_user_id: owner_id,
           shared: shared,
           model: model,
           parent_id: parent_id,
           depth: depth
         },
         names_by_id
       ) do
    %{
      name: name,
      space_id: sid,
      model: model,
      parent_id: parent_id,
      parent_name: Map.get(names_by_id, parent_id),
      depth: depth,
      created_by_user_id: owner_id,
      shared: shared == true,
      status: :idle,
      archived: true
    }
  end

  # `id => name` for every agent row in the space (archived or
  # not) so a persisted row's `parent_name` can be resolved even
  # when its parent is not part of the result set.
  defp agent_names_by_id(space_id) do
    from(a in PersistedAgent,
      where: a.space_id == ^space_id,
      select: {a.id, a.name}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp fetch_from_registry(space_id, name, user_id) do
    with {:ok, pid} <- Registry.lookup(space_id, name),
         %{space_id: sid} = info <- fetch_public_info(pid),
         true <- visible_to?(info, user_id) do
      Map.put(info, :space_id, sid)
    else
      _ -> nil
    end
  end

  # A registry-resident pid can die between `Registry.lookup/2`
  # and the call landing; treat any exit as "not found" so one
  # dead agent can't abort the whole listing.
  defp fetch_public_info(pid) do
    Agent.get_public_info(pid)
  catch
    :exit, _ -> nil
  end

  # `nil` user_id means "no per-user filter" (space-scoped listing).
  defp visible_to?(_info, nil), do: true

  defp visible_to?(%{created_by_user_id: id, shared: shared}, user_id),
    do: id == user_id or shared == true

  # Backfill from the `agents` table so an agent whose
  # BEAM pid is currently down (e.g. crashed and not yet
  # restarted) still shows up in the lobby. The on-demand
  # loader in `Supervisor.get_agent/2` will rehydrate it
  # when the user clicks. Rows are ordered by name so this
  # branch is deterministic on its own; the caller re-sorts
  # the merged list by name (see `list_agents/2`).
  defp persisted_visible(space_id, user_id) do
    names_by_id = agent_names_by_id(space_id)
    slugs_by_id = vocation_slugs_by_id()

    from(a in PersistedAgent,
      where: a.space_id == ^space_id,
      where: a.archived == false,
      order_by: a.name
    )
    |> filter_visible_to(user_id)
    |> Repo.all()
    |> Enum.map(&non_archived_info(&1, names_by_id, slugs_by_id))
  end

  # `id => slug` for every vocation. A persisted agent row stores
  # only `vocation_id`, so its slug is resolved here (mirroring
  # `agent_names_by_id/1` for `parent_name`) rather than left nil —
  # the `agents-list` tool reports the vocation slug of every agent,
  # running or not.
  defp vocation_slugs_by_id do
    Vocations.list_vocations()
    |> Map.new(&{&1.id, &1.slug})
  end

  # `nil` user_id means "no per-user filter" (space-scoped listing).
  defp filter_visible_to(query, nil), do: query

  defp filter_visible_to(query, user_id) do
    from(a in query, where: a.created_by_user_id == ^user_id or a.shared == true)
  end

  defp non_archived_info(
         %PersistedAgent{
           name: name,
           space_id: sid,
           vocation_id: vocation_id,
           created_by_user_id: owner_id,
           shared: shared,
           model: model,
           parent_id: parent_id,
           depth: depth
         },
         names_by_id,
         slugs_by_id
       ) do
    %{
      name: name,
      space_id: sid,
      model: model,
      vocation_slug: Map.get(slugs_by_id, vocation_id),
      parent_id: parent_id,
      parent_name: Map.get(names_by_id, parent_id),
      depth: depth,
      created_by_user_id: owner_id,
      shared: shared == true,
      status: :idle
    }
  end
end
