defmodule Nest.Persistence.AgentCompaction.Writer do
  @moduledoc """
  Applies an `AgentCompaction.Planner` plan in one transaction.

  Order inside the transaction:

    1. delete the orphan rows past the summarized prefix (a crashed
       compaction's partial write);
    2. insert the `role: "compaction"` marker at `marker_index`;
    3. insert the new system + summary rows at `marker_index + 1/+2`;
    4. move `agents.last_compaction_index` to the marker and
       `next_message_index` past the new rows.

  The whole run rolls back on any failure.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Compaction
  alias Nest.Persistence
  alias Nest.Persistence.AgentCompaction.Planner
  alias Nest.Repo
  alias Nest.Tokens.Estimator

  @doc """
  Apply `plan` with `summary`. Returns `:ok`, or `{:error, reason}`
  after rolling back every write.
  """
  @spec apply(Planner.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def apply(%Planner{} = plan, summary, opts \\ []) when is_binary(summary) do
    now = Keyword.get(opts, :now, Persistence.now())

    Repo.transaction(fn ->
      delete_orphans(plan)
      insert_marker(plan, summary, now)
      Enum.each(Planner.new_messages(plan, summary, now), &insert_row(plan.agent_id, &1))
      update_agent(plan, now)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_orphans(%Planner{} = plan) do
    from_index = Planner.orphan_from(plan)

    from(m in PersistedMessage,
      where: m.agent_id == ^plan.agent_id and m.message_index >= ^from_index
    )
    |> Repo.delete_all()
  end

  defp insert_marker(%Planner{} = plan, summary, now) do
    new_messages = Planner.new_messages(plan, summary, now)

    marker = %Compaction{
      index: plan.marker_index,
      archived_count: plan.archived_count,
      compaction_count: plan.compaction_count,
      tokens_compacted: Estimator.estimate_messages(plan.slice),
      tokens_compacted_to: Estimator.estimate_messages(new_messages),
      occurred_at: now,
      metadata: nil
    }

    insert_row(plan.agent_id, {:compaction, marker})
  end

  defp insert_row(agent_id, message) do
    attrs = PersistedMessage.from_runtime(agent_id, message)

    case %PersistedMessage{}
         |> PersistedMessage.changeset(attrs)
         |> Repo.insert() do
      {:ok, _row} -> :ok
      {:error, reason} -> Repo.rollback({:insert_failed, message, reason})
    end
  end

  defp update_agent(%Planner{} = plan, now) do
    new_count = length(Planner.new_messages(plan, "", now))

    from(a in PersistedAgent, where: a.id == ^plan.agent_id)
    |> Repo.update_all(
      set: [
        last_compaction_index: plan.marker_index,
        next_message_index: plan.marker_index + 1 + new_count,
        updated_at: now
      ]
    )
  end
end
