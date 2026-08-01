defmodule Nest.Persistence.Messages do
  @moduledoc """
  Message-load and agent-counter helpers extracted from
  `Nest.Persistence` so the parent module stays under the
  credo 500-line cap.

  Owns the per-agent reads (`load_messages/1`,
  `last_compaction_index/1`) and the `update_next_message_index/2`
  counter bump. The agent-row CRUD (insert/fetch) stays in
  `Nest.Persistence` proper, and the row-attribute mutators
  (model, total updates) live in `Nest.Persistence.AgentAttrs`.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Message
  alias Nest.Repo

  @doc """
  Load every message for an agent (active + history + compaction
  markers), in `message_index` order. Returns a list of
  `Message.t()` tagged tuples — the canonical runtime shape.

  Used by the on-demand-load path in
  `Supervisor.fetch_or_start_agent/1`. The caller partitions
  into active/history using `agents.last_compaction_index`;
  this function never inspects that boundary itself.
  """
  @spec load_messages(String.t()) :: [Message.t()]
  def load_messages(agent_name) do
    case fetch_agent_by_name(agent_name) do
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

  @doc """
  Read the `last_compaction_index` boundary column from the
  agents row. Returns `{:ok, -1}` for fresh agents (no
  compaction has happened) and the marker's `message_index`
  (an integer `>= 0`) after the first compaction. Returns
  `{:error, :agent_not_found}` when the name does not resolve.

  Used by the on-demand-load path in
  `Supervisor.fetch_or_start_agent/1` and by callers that need
  the boundary without a full message load.
  """
  @spec last_compaction_index(String.t()) ::
          {:ok, integer()} | {:error, :agent_not_found}
  def last_compaction_index(agent_name) do
    case fetch_agent_by_name(agent_name) do
      {:ok, %PersistedAgent{last_compaction_index: idx}} -> {:ok, idx}
      {:error, :not_found} -> {:error, :agent_not_found}
    end
  end

  @doc """
  Bump the `next_message_index` column on the agent row.

  Called after every successful `insert_message/2` so a
  restarted agent reads the right counter on the next message
  append. One UPDATE per message; a single agent's counter
  is in a single row, so this is O(1).
  """
  @spec update_next_message_index(String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def update_next_message_index(agent_name, new_index) do
    case fetch_agent_by_name(agent_name) do
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

  defp fetch_agent_by_name(name) do
    Nest.Persistence.fetch_agent_by_name(name)
  end
end
