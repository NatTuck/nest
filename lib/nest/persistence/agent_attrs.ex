defmodule Nest.Persistence.AgentAttrs do
  @moduledoc """
  Agent-row attribute mutators extracted from `Nest.Persistence`
  so the parent module stays under the credo 500-line cap.

  `update_agent_model/3` and `fetch_all_agents/0` are the only
  agent-row UPDATEs the runtime path issues outside of
  `insert_agent/1` and the message-write helpers.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence
  alias Nest.Repo

  @spec update_agent_model(integer(), String.t(), map()) :: :ok | {:error, term()}
  def update_agent_model(space_id, name, model_map) when is_map(model_map) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            model: model_map,
            updated_at: Persistence.now()
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec update_agent_workspace(integer(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def update_agent_workspace(space_id, name, workspace_path) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            workspace_path: workspace_path,
            updated_at: Persistence.now()
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec update_agent_mode(integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_agent_mode(space_id, name, mode) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            mode: mode,
            updated_at: Persistence.now()
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec fetch_all_agents_for_space(integer()) :: [PersistedAgent.t()]
  def fetch_all_agents_for_space(space_id) when is_integer(space_id) do
    from(a in PersistedAgent, where: a.space_id == ^space_id, order_by: a.name)
    |> Repo.all()
  end

  @doc """
  Every agent row in the database, ordered by `id`.

  Offline tooling (`mix nest.repair_messages --all`) uses this
  to reach agents across every space in one pass.
  """
  @spec list_all_agents() :: [PersistedAgent.t()]
  def list_all_agents do
    from(a in PersistedAgent, order_by: [asc: a.id]) |> Repo.all()
  end

  @spec archive_agent(integer(), String.t()) :: :ok | {:error, :not_found}
  def archive_agent(space_id, name) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            archived: true,
            updated_at: Persistence.now()
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Restore the archived row for `{space_id, name}` **and its whole
  archived subtree**, walking the persisted `parent_id` links.

  `Nest.Agents.ChildRegistry` cannot be used here: archiving a parent
  stops its descendants, so their registry entries are gone by the time
  anyone wants them back. The rows are the only surviving record of the
  tree's shape.

  Returns `{:ok, names}` with the names actually restored, sorted by
  name so the caller's broadcasts are deterministic. Restoring a row
  that is already active is a no-op — `{:ok, []}`, not an error.

  Restoring a child whose parent is still archived is refused with
  `{:error, {:parent_archived, parent_name}}`: the sidebar nests the
  tree by `parent_name`, so the restored child would render inside the
  archived parent's collapsed `Archived` group — it would look exactly
  like the restore did nothing.
  """
  @spec unarchive_agent(integer(), String.t()) ::
          {:ok, [String.t()]}
          | {:error, :not_found | {:parent_archived, String.t()}}
  def unarchive_agent(space_id, name) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{archived: true} = row} ->
        case archived_parent_name(space_id, row) do
          nil -> restore_subtree(space_id, row)
          parent -> {:error, {:parent_archived, parent}}
        end

      {:ok, %PersistedAgent{}} ->
        {:ok, []}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # The parent's name when this row's parent is itself still archived;
  # `nil` for a root, and for a child whose parent row is gone (nothing
  # left to nest it under, so it is restorable).
  defp archived_parent_name(_space_id, %PersistedAgent{parent_id: nil}), do: nil

  defp archived_parent_name(space_id, %PersistedAgent{parent_id: parent_id}) do
    from(a in PersistedAgent,
      where: a.space_id == ^space_id,
      where: a.id == ^parent_id,
      where: a.archived == true,
      select: a.name
    )
    |> Repo.one()
  end

  # Clear `archived` for the whole subtree in one statement, and return
  # the restored names in name order. The root row is archived by
  # construction (the caller checked), so this always restores at least
  # it.
  defp restore_subtree(space_id, %PersistedAgent{id: root_id}) do
    subtree = subtree_ids(space_id, [root_id], [root_id])

    restored =
      from(a in PersistedAgent,
        where: a.space_id == ^space_id,
        where: a.id in ^subtree,
        where: a.archived == true,
        order_by: a.name,
        select: {a.name, a.id}
      )
      |> Repo.all()

    from(a in PersistedAgent, where: a.id in ^Enum.map(restored, &elem(&1, 1)))
    |> Repo.update_all(set: [archived: false, updated_at: Persistence.now()])

    {:ok, Enum.map(restored, &elem(&1, 0))}
  end

  # Every row id in the subtree rooted at `level`, found by walking
  # `parent_id` one level at a time. `seen` accumulates the result and
  # also keeps a corrupt parent cycle from looping forever.
  defp subtree_ids(space_id, level, seen) do
    children =
      from(a in PersistedAgent,
        where: a.space_id == ^space_id,
        where: a.parent_id in ^level,
        select: a.id
      )
      |> Repo.all()
      |> Enum.reject(&(&1 in seen))

    case children do
      [] -> seen
      fresh -> subtree_ids(space_id, fresh, seen ++ fresh)
    end
  end
end
