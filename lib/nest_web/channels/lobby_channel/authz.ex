defmodule NestWeb.LobbyChannel.Authz do
  @moduledoc """
  Authorization helpers for the LobbyChannel handlers that
  mutate agents (`delete_agent`, `change_model`, etc).

  Pure functions over `(space_id, name, current_user)` — no
  socket, no logging. Kept in a sibling file so `LobbyChannel`
  stays under the credo 500-line cap.

  ## Permission rules

    * `delete_agent` — owner only. Shared agents are
      chat-visible but not deletable by non-owners.
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

  @doc "Owner-only check used by `delete_agent`."
  def authorize_owner(space_id, name, current_user) do
    case fetch_visibility(space_id, name) do
      {:ok, %{created_by_user_id: id}} when id == current_user.id -> :ok
      {:ok, _} -> {:error, :forbidden}
      :error -> {:error, :not_found}
    end
  end

  @doc "Owner-or-shared check used by `change_model`."
  def authorize_owner_or_shared(space_id, name, current_user) do
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
