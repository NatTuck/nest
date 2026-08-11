defmodule Nest.Persistence.Messages do
  @moduledoc """
  Message-load and agent-counter helpers extracted from
  `Nest.Persistence` so the parent module stays under the
  credo 500-line cap.

  Owns the per-agent reads (`load_messages/2`,
  `last_compaction_index/2`) and the `update_next_message_index/3`
  counter bump. All functions take `space_id` as the first
  argument since agent names are unique within a space.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Message
  alias Nest.Repo

  @spec load_messages(integer(), String.t()) :: [Message.t()]
  def load_messages(space_id, agent_name) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        from(m in PersistedMessage,
          where: m.agent_id == ^agent_id,
          order_by: [asc: m.message_index]
        )
        |> Repo.all()
        |> Enum.map(&PersistedMessage.to_runtime/1)

      {:error, :not_found} ->
        []
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
end
