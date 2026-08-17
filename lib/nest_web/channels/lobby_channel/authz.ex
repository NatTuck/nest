defmodule NestWeb.LobbyChannel.Authz do
  @moduledoc """
  Authorization helpers for the LobbyChannel handlers that
  mutate agents (`change_model`, etc).

  Pure functions over `(space_id, name, current_user)` — no
  socket, no logging. Kept in a sibling file so `LobbyChannel`
  stays under the credo 500-line cap.

  ## Permission rules

    * `change_model` — owner only. Shared-agent viewers
      can't rewrite the model of a shared agent (the JS
      side surfaces the `:shared_read_only` error).

  ## Lookup precedence

  When the agent's pid is alive in the supervisor's
  `Registry`, the runtime state's `:created_by_user_id` /
  `:shared` are read directly. When the supervisor has lost
  the pid (crash, normal shutdown between requests), we
  fall back to the persisted row — covers the on-demand-load
  path where the row exists but the supervisor hasn't
  started the process yet.
  """

  alias Nest.Agents
  alias Nest.Agents.PersistedAgent
  alias Nest.Spaces

  @doc "Owner-or-shared check used by `change_model`."
  def authorize_owner_or_shared(space_id, name, current_user) do
    with :ok <- ensure_space_active(space_id) do
      case fetch_visibility(space_id, name) do
        {:ok, %{created_by_user_id: id}} when id == current_user.id ->
          {:ok, :owner}

        {:ok, %{shared: shared}} when shared == true ->
          {:ok, :shared}

        {:ok, _} ->
          {:error, :forbidden}

        :error ->
          {:error, :not_found}
      end
    end
  end

  @doc "Owner-only check for space-level operations (archive/unarchive)."
  def authorize_space_owner(space_id, current_user) do
    case Spaces.get_space(space_id) do
      %Nest.Spaces.Space{created_by_user_id: id} when id == current_user.id ->
        {:ok, :owner}

      %Nest.Spaces.Space{} ->
        {:error, :forbidden}

      _ ->
        {:error, :not_found}
    end
  end

  # A space-level mutation must not proceed on an archived
  # space — its agents are stopped and the space is hidden.
  defp ensure_space_active(space_id) do
    case Spaces.get_space(space_id) do
      %Nest.Spaces.Space{archived: true} -> {:error, :space_archived}
      %Nest.Spaces.Space{} -> :ok
      _ -> {:error, :not_found}
    end
  end

  # Read the `created_by_user_id` / `shared` pair from the
  # Agent's runtime state, falling back to the persisted row
  # when the supervisor has no live pid. The returned map's
  # keys are uniform across both sources so the callers can
  # pattern-match on `created_by_user_id` / `shared` directly.
  defp fetch_visibility(space_id, name) do
    case Agents.Registry.lookup(space_id, name) do
      {:ok, pid} ->
        try do
          info = Agents.Agent.get_public_info(pid)
          {:ok, %{created_by_user_id: info.created_by_user_id, shared: info.shared}}
        catch
          :exit, _ -> fetch_from_db(space_id, name)
        end

      _ ->
        fetch_from_db(space_id, name)
    end
  end

  # Persisted-row fallback. Used when the supervisor's
  # `Registry` lookup misses entirely (no pid registered) OR
  # the pid is registered but already dead (the GenServer.call
  # raises `:exit` in that case — see `fetch_visibility/2`).
  defp fetch_from_db(space_id, name) do
    case Nest.Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{created_by_user_id: id, shared: shared}} ->
        {:ok, %{created_by_user_id: id, shared: shared == true}}

      _ ->
        :error
    end
  end
end
