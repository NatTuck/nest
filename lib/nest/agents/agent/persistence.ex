defmodule Nest.Agents.Agent.Persistence do
  @moduledoc """
  Agent-side glue around `Nest.Persistence`.

  Persists the messages and compaction markers the runtime
  produces. The Agent's `init/1` and `__append_message__/2`
  paths call through here.
  """

  require Logger

  alias Nest.Agents.PersistedMessage
  alias Nest.Persistence

  @doc """
  Persist a freshly-stamped message into the `messages`
  table and bump the agent's `next_message_index`.

  The row is addressed by `{state.space_id, state.name}` — the runtime
  handle — and checked against `state.chat_state.agent_row_id`, the
  `agents.id` this session was started from. A name whose row was
  deleted out from under this process and then taken over by a
  *different* agent resolves to the successor's row, and writing there
  would silently corrupt another agent's transcript; that append is
  dropped and logged instead (see `Persistence.insert_message/4`).

  The counter bump follows the row the INSERT returned (`agents.id`),
  never the name: a takeover landing between the two writes would
  otherwise move the successor's counter with no message to justify it.

  Always returns `:ok`. The append is in-memory-first, so a persistence
  failure must not fail the turn — it is logged instead, and only the one
  shape that writes no row at all (a `{:compaction, _}` tuple whose
  payload is not a `%Compaction{}`) leaves the counter alone.
  """
  @spec append_message(Nest.Agents.Agent.t(), {atom(), map()}, non_neg_integer()) :: :ok
  def append_message(%{space_id: space_id, name: name} = state, stamped, new_index)
      when is_integer(space_id) and is_binary(name) do
    case Persistence.insert_message(space_id, name, stamped,
           expect_agent_row_id: state.chat_state.agent_row_id
         ) do
      {:ok, %PersistedMessage{agent_id: agent_id}} ->
        :ok = Persistence.update_next_message_index_by_id(agent_id, new_index)

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist message for agent #{name}: #{inspect(reason)}")
    end
  end

  def append_message(_state, _stamped, _new_index), do: :ok

  @doc """
  Persist a compaction marker through the same row check as
  `append_message/3`: the marker must land on the row this session was
  started from, or it is dropped and logged. A marker in a successor's
  row would move *its* archived boundary.

  Returns `:ok` on success (or on a dropped marker, matching
  `append_message/3`), `{:error, reason}` when the write failed.
  """
  @spec record_compaction(
          Nest.Agents.Agent.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: :ok | {:error, term()}
  def record_compaction(
        state,
        marker_index,
        archived_count,
        tokens_compacted \\ nil,
        tokens_compacted_to \\ nil
      ) do
    case Persistence.record_compaction(
           state.space_id,
           state.name,
           marker_index,
           archived_count,
           tokens_compacted,
           tokens_compacted_to,
           expect_agent_row_id: state.chat_state.agent_row_id
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist compaction for agent #{state.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
