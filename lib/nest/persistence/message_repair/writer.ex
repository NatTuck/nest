defmodule Nest.Persistence.MessageRepair.Writer do
  @moduledoc """
  Applies a `Nest.Persistence.MessageRepair.Planner` plan to the
  database in a single transaction.

  The write is two-phase per changed agent to avoid transient
  collisions on the `(agent_id, message_index)` unique index: every
  row of a changed agent is first moved to a large temporary offset,
  then every row is given its final index (and synthetic rows are
  inserted). The whole run rolls back on any failure.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Persistence.MessageRepair.Planner
  alias Nest.Repo

  @offset 1_000_000_000

  @doc """
  Apply `plan`. Returns `:ok`, or `{:error, reason}` after rolling
  back every write.
  """
  @spec apply(Planner.t()) :: :ok | {:error, term()}
  def apply(%Planner{} = plan) do
    Repo.transaction(fn ->
      Enum.each(plan.changed_agents, &offset_agent/1)
      run!(renumber(plan.renumbers))
      run!(rewrite(plan.rewrites))
      run!(insert_synthetics(plan.inserts))
      run!(update_agents(plan.agent_updates))
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run!(:ok), do: :ok
  defp run!({:error, reason}), do: Repo.rollback(reason)

  defp offset_agent(agent_id) do
    query = from(m in PersistedMessage, where: m.agent_id == ^agent_id)

    Repo.update_all(query,
      set: [message_index: dynamic([m], m.message_index + ^@offset)]
    )
  end

  defp renumber(rows) do
    Enum.reduce_while(rows, :ok, fn %{id: id, index: index}, :ok ->
      query = from(m in PersistedMessage, where: m.id == ^id)

      case Repo.update_all(query, set: [message_index: index]) do
        {_count, _} -> {:cont, :ok}
        other -> {:halt, {:error, {:renumber_failed, id, other}}}
      end
    end)
  end

  defp rewrite(rows) do
    Enum.reduce_while(rows, :ok, fn %{id: id, agent_id: agent_id, runtime: runtime}, :ok ->
      attrs = PersistedMessage.from_runtime(agent_id, runtime)
      query = from(m in PersistedMessage, where: m.id == ^id)

      case Repo.update_all(query, set: [content: attrs.content, metadata: attrs.metadata]) do
        {_count, _} -> {:cont, :ok}
        other -> {:halt, {:error, {:rewrite_failed, id, other}}}
      end
    end)
  end

  defp insert_synthetics(rows) do
    Enum.reduce_while(rows, :ok, fn %{agent_id: agent_id, runtime: runtime}, :ok ->
      attrs = PersistedMessage.from_runtime(agent_id, runtime)
      changeset = PersistedMessage.changeset(%PersistedMessage{}, attrs)

      case Repo.insert(changeset) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:insert_failed, agent_id, reason}}}
      end
    end)
  end

  defp update_agents(updates) do
    now = Nest.Persistence.now()

    Enum.reduce_while(updates, :ok, fn {agent_id, update}, :ok ->
      query = from(a in PersistedAgent, where: a.id == ^agent_id)

      case Repo.update_all(query, set: Map.to_list(Map.put(update, :updated_at, now))) do
        {_count, _} -> {:cont, :ok}
        other -> {:halt, {:error, {:agent_update_failed, agent_id, other}}}
      end
    end)
  end
end
