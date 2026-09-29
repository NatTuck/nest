defmodule Nest.Agents.Agent.Persistence do
  @moduledoc """
  Agent-side glue around `Nest.Persistence`.

  Persists the messages and compaction markers the runtime
  produces. The Agent's `init/1` and `__append_message__/2`
  paths call through here.
  """

  require Logger

  alias Nest.Persistence

  @doc """
  Persist a freshly-stamped message into the `messages`
  table and bump the agent's `next_message_index`.
  """
  def append_message(space_id, agent_id, stamped, new_index)
      when is_integer(space_id) and is_binary(agent_id) do
    case Persistence.insert_message(space_id, agent_id, stamped) do
      {:ok, _row} ->
        :ok = Persistence.update_next_message_index(space_id, agent_id, new_index)

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist message for agent #{agent_id}: #{inspect(reason)}")
    end
  end

  def append_message(_space_id, _agent_id, _stamped, _new_index), do: :ok

  def record_compaction(
        space_id,
        agent_id,
        marker_index,
        archived_count,
        tokens_compacted \\ nil,
        tokens_compacted_to \\ nil
      ) do
    case Persistence.record_compaction(
           space_id,
           agent_id,
           marker_index,
           archived_count,
           tokens_compacted,
           tokens_compacted_to
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist compaction for agent #{agent_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
