defmodule Nest.Agents.Visibility do
  @moduledoc """
  Per-user agent visibility helpers used by the lobby.

  A user sees two classes of agent:

    * their own private agents (`created_by_user_id == user.id`
      and `shared == false`)
    * every shared agent (`shared == true`)

  `Nest.Agents.list_visible_agents_for/1` is the public entry
  point; the lobby channel calls it from `:after_join` to
  populate the `init` payload's `agents` field. The
  companion `Nest.Agents.list_broken_agents_for/1` is used
  by the lobby's follow-up `broken_agents_updated` push.

  Lives in a separate file so the `Nest.Agents` module
  doesn't grow past the credo 500-line cap.
  """

  alias Nest.Agents.Agent

  @doc """
  Public-info map for every agent the given user is allowed
  to see. Same shape as `Agents.list_agents_info/0`; only
  the membership predicate differs.
  """
  @spec list_visible_agents_for(integer()) :: [map()]
  def list_visible_agents_for(user_id) when is_integer(user_id) do
    user_id
    |> list_agent_names_for()
    |> Enum.map(&Nest.Agents.get_info/1)
    |> Enum.filter(fn
      {:ok, info} -> info
      _ -> nil
    end)
    |> Enum.map(fn {:ok, info} -> info end)
  end

  # Names of agents visible to `user_id`: every shared agent
  # plus the user's own private agents. The Registry's
  # `list/0` only returns agents that are alive in the
  # supervisor, so agents that haven't been started since
  # the BEAM boot are skipped here. The full picture
  # (including not-yet-started rows) lives in `Persistence.
  # fetch_all_agents/0` and is used by `list_broken_agents/0`
  # for the repair flow.
  defp list_agent_names_for(user_id) do
    Nest.Agents.Registry.list()
    |> Enum.filter(&visible_to?(&1, user_id))
  end

  defp visible_to?(name, user_id) do
    case Nest.Agents.Registry.lookup(name) do
      {:ok, pid} -> fetch_visibility_from_pid(pid, user_id)
      _ -> false
    end
  end

  # Reads `created_by_user_id` / `shared` off the agent's
  # runtime state. Catches the GenServer.exit that fires when
  # the pid was registered but has already terminated (the
  # Registry holds the entry until the supervisor's child
  # spec unregisters it, which can race with our list loop
  # if a parallel test just stopped an agent). When that
  # happens we return `false` — the agent was no longer
  # alive for that test to see, and the supervisor will
  # hydrate it on demand if needed elsewhere.
  defp fetch_visibility_from_pid(pid, user_id) do
    info =
      try do
        Agent.get_public_info(pid)
      catch
        :exit, _ -> nil
      end

    case info do
      nil -> false
      %{} -> info.created_by_user_id == user_id or info.shared == true
    end
  end
end
