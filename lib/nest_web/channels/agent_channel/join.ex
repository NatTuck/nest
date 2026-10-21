defmodule NestWeb.AgentChannel.Join do
  @moduledoc """
  The join-time authorization for `NestWeb.AgentChannel`: who may sit on
  `agent:<space_id>:<name>`.

  It lives here rather than in the channel to keep that module within its file
  budget — the same split as `History`, `Pane`, `Replies`, `ShellLog` and `Sync`.
  """

  alias Nest.Agents
  alias Nest.Agents.PersistedAgent

  @doc """
  Allow the join when the user owns the agent or the agent is shared.

  `Agent.get_public_info/1` is the source of truth for ownership and visibility
  — the runtime state carries the same fields the DB row does, so this avoids a
  separate `fetch_agent/2` round-trip. But it is a call, and the pid the Registry
  hands back can already be doomed: the agent traps exits, so
  `Supervisor.stop_agent/2` only queues its `:shutdown` and the name stays
  registered. An exit here would kill the channel during `join/3`, leaving the
  client with a closed socket instead of the refusal.
  `NestWeb.LobbyChannel.Authz.fetch_visibility/2` guards the same shape the same
  way.
  """
  @spec authorize(integer(), String.t(), map()) :: :ok | {:error, :not_found | :forbidden}
  def authorize(space_id, name, current_user) do
    case Agents.Registry.lookup(space_id, name) do
      {:ok, pid} ->
        try do
          authorize_from(Agents.Agent.get_public_info(pid), current_user)
        catch
          :exit, _ -> from_row(space_id, name, current_user)
        end

      _ ->
        from_row(space_id, name, current_user)
    end
  end

  # The supervisor's on-demand loader can hydrate an agent that is not currently
  # in the Registry, and a pid that died under `get_public_info/1` is the same
  # case one step later. Fall back to the DB row for both.
  defp from_row(space_id, name, current_user) do
    case Nest.Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{} = row} -> authorize_from(row, current_user)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Shared predicate for both runtime and persisted rows. The schema field name
  # `created_by_user_id` matches the runtime state field name, so we can
  # destructure either uniformly.
  defp authorize_from(%{created_by_user_id: id, shared: shared}, current_user)
       when id == current_user.id or shared == true,
       do: :ok

  defp authorize_from(%PersistedAgent{created_by_user_id: id, shared: shared}, current_user)
       when id == current_user.id or shared == true,
       do: :ok

  defp authorize_from(_other, _current_user), do: {:error, :forbidden}
end
