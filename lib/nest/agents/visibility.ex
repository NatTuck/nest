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
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.Agent
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Registry
  alias Nest.Repo

  @doc """
  Public-info map for every agent in `space_id` the
  given user is allowed to see. Returns a list of maps
  with `space_id`, `name`, and the rest of the public
  info.
  """
  @spec list_visible_agents_for(integer(), integer()) :: [map()]
  def list_visible_agents_for(space_id, user_id)
      when is_integer(space_id) and is_integer(user_id) do
    space_id
    |> Registry.list_for_space()
    |> Enum.map(&fetch_from_registry(space_id, &1, user_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(persisted_visible(space_id, user_id))
    |> Enum.uniq_by(& &1.name)
  end

  defp fetch_from_registry(space_id, name, user_id) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        info =
          try do
            Agent.get_public_info(pid)
          catch
            :exit, _ -> nil
          end

        case info do
          nil ->
            nil

          %{created_by_user_id: id, shared: shared, space_id: sid}
          when id == user_id or shared == true ->
            Map.put(info, :space_id, sid)

          _ ->
            nil
        end

      {:error, :not_found} ->
        nil
    end
  end

  # Backfill from the `agents` table so an agent whose
  # BEAM pid is currently down (e.g. crashed and not yet
  # restarted) still shows up in the lobby. The on-demand
  # loader in `Supervisor.get_agent/2` will rehydrate it
  # when the user clicks.
  defp persisted_visible(space_id, user_id) do
    from(a in PersistedAgent,
      where: a.space_id == ^space_id,
      where: a.created_by_user_id == ^user_id or a.shared == true
    )
    |> Repo.all()
    |> Enum.map(fn %PersistedAgent{
                     name: name,
                     space_id: sid,
                     created_by_user_id: owner_id,
                     shared: shared,
                     model: model,
                     parent_id: parent_id,
                     depth: depth
                   } ->
      %{
        name: name,
        space_id: sid,
        model: model,
        parent_id: parent_id,
        depth: depth,
        created_by_user_id: owner_id,
        shared: shared == true,
        status: :idle
      }
    end)
  end
end
