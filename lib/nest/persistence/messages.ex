defmodule Nest.Persistence.Messages do
  @moduledoc """
  Message-load and agent-counter helpers extracted from
  `Nest.Persistence` so the parent module stays under the
  credo 500-line cap.

  Owns the per-agent reads (`load_messages/2`,
  `load_full_messages/2`, `last_compaction_index/2`) and the
  `update_next_message_index/3` / `update_fork_message_index/3`
  counter bumps. All functions take `space_id` as the first
  argument since agent names are unique within a space.

  `load_messages/2` returns only the rows the agent *owns*.
  `load_full_messages/2` returns the agent's full logical
  sequence by recursively resolving the shared prefix through
  `parent_id` (see `notes/shared-message-structure.md`).
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Message
  alias Nest.Repo

  @spec load_messages(integer(), String.t()) :: [Message.t()]
  def load_messages(space_id, agent_name) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{id: agent_id}} -> load_own_messages(agent_id)
      {:error, :not_found} -> []
    end
  end

  @doc """
  Load an agent's full logical sequence: its own rows plus the
  ancestor rows it shares below its `fork_message_index`,
  resolved recursively via `parent_id`.

  A root or fresh child (`fork_message_index` is `nil`) resolves
  to its own rows. A clone resolves to
  `before(full(parent), fork) ++ own`, where `before/2` keeps
  rows with a lower `message_index`.
  """
  @spec load_full_messages(integer(), String.t()) :: [Message.t()]
  def load_full_messages(space_id, agent_name) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, row} -> resolve_full(row, MapSet.new())
      {:error, :not_found} -> []
    end
  end

  @spec load_own_messages(integer()) :: [Message.t()]
  def load_own_messages(agent_id) when is_integer(agent_id) do
    from(m in PersistedMessage,
      where: m.agent_id == ^agent_id,
      order_by: [asc: m.message_index]
    )
    |> Repo.all()
    |> Enum.map(&PersistedMessage.to_runtime/1)
  end

  @doc """
  Bulk-load the *schema* rows for a set of agents, grouped by
  `agent_id` and ordered by `message_index`. Unlike
  `load_own_messages/1`, this keeps the `%PersistedMessage{}`
  rows (with their primary keys) so the offline repair tool can
  renumber and rewrite them.
  """
  @spec load_rows_by_agent([integer()]) :: %{integer() => [PersistedMessage.t()]}
  def load_rows_by_agent(agent_ids) when is_list(agent_ids) do
    from(m in PersistedMessage,
      where: m.agent_id in ^agent_ids,
      order_by: [asc: m.agent_id, asc: m.message_index]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.agent_id)
  end

  defp resolve_full(%PersistedAgent{} = row, seen) do
    own = load_own_messages(row.id)

    case shared_parent(row, seen) do
      {:ok, parent, fork} ->
        parent
        |> resolve_full(MapSet.put(seen, row.id))
        |> Enum.filter(fn {_role, %{index: idx}} -> idx < fork end)
        |> Kernel.++(own)

      :none ->
        own
    end
  end

  # The parent to inherit a shared prefix from, or `:none` for a
  # root, a fresh child, a detached clone, a cycle, or a missing
  # parent row.
  defp shared_parent(%PersistedAgent{parent_id: parent_id, fork_message_index: fork}, seen)
       when is_integer(parent_id) and is_integer(fork) do
    if MapSet.member?(seen, parent_id) do
      :none
    else
      case fetch_agent_by_id(parent_id) do
        {:ok, parent} -> {:ok, parent, fork}
        {:error, :not_found} -> :none
      end
    end
  end

  defp shared_parent(_row, _seen), do: :none

  @spec fetch_agent_by_id(integer()) :: {:ok, PersistedAgent.t()} | {:error, :not_found}
  defp fetch_agent_by_id(id) do
    case Repo.get(PersistedAgent, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @spec last_compaction_index(integer(), String.t()) ::
          {:ok, integer()} | {:error, :agent_not_found}
  def last_compaction_index(space_id, agent_name) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{last_compaction_index: idx}} -> {:ok, idx}
      {:error, :not_found} -> {:error, :agent_not_found}
    end
  end

  @spec update_next_message_index(integer(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def update_next_message_index(space_id, agent_name, new_index) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        now = Nest.Persistence.now()

        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            next_message_index: new_index,
            updated_at: now
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Set (or clear, with `nil`) an agent's fork boundary. Used by the
  clone detach path at first compaction (see
  `notes/shared-message-structure.md`).
  """
  @spec update_fork_message_index(integer(), String.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def update_fork_message_index(space_id, agent_name, fork_message_index)
      when is_integer(fork_message_index) or is_nil(fork_message_index) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        now = Nest.Persistence.now()

        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            fork_message_index: fork_message_index,
            updated_at: now
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :agent_not_found}
    end
  end
end
