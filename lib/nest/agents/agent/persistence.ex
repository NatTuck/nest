defmodule Nest.Agents.Agent.Persistence do
  @moduledoc """
  Agent-side glue around `Nest.Persistence`.

  Persists the messages and compaction markers the runtime
  produces. The Agent's `init/1` and `__append_message__/2`
  paths call through here.

  ## The cached `agents.id`

  Every caller above this module identifies an agent by
  `{space_id, name}`, but `messages.agent_id` is the integer
  `agents.id` (a `bigserial`). Resolving the name to that id is a
  SELECT, and the append path used to pay two of them per message —
  one for the INSERT, one for the `next_message_index` UPDATE.
  Instead the id is resolved once per agent process and cached on
  `state.chat_state.agent_row_id`: seeded from the start attrs
  (`Nest.Persistence.build_attrs_for_start/2` already read the row)
  and lazily resolved on the first append otherwise. An append after
  that is exactly two statements: the message INSERT and the counter
  UPDATE.

  The cache cannot go stale in a way that corrupts data. `agents.id`
  is a `bigserial` primary key, so a deleted row's id is never
  reissued to a different agent; a cached id can therefore only ever
  point at *this* agent's row, or at nothing. If the row is gone (the
  space teardown path stops the process and deletes the rows
  concurrently), the INSERT fails its foreign key and the append is
  logged and dropped — the same outcome as the `fetch_agent/2` miss it
  replaces.
  """

  require Logger

  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Message
  alias Nest.Persistence

  @doc """
  Persist a freshly-stamped message into the `messages` table and bump
  the agent's `next_message_index` to `new_index` (the index the next
  append will use).

  Returns `state` with the resolved `agents.id` cached on
  `chat_state.agent_row_id`, so the caller must rebind it. An INSERT
  failure is logged and dropped: the in-memory sequence is the
  runtime's source of truth, and the dropped append is exactly what the
  old `fetch_agent/2` miss produced. The counter bump keeps its
  pre-existing strict `:ok =` match, so a row that vanishes between the
  two writes still fails loudly rather than silently diverging.
  """
  @spec append_message(Nest.Agents.Agent.t(), Message.t(), non_neg_integer()) ::
          Nest.Agents.Agent.t()
  def append_message(state, stamped, new_index) do
    case agent_row_id(state) do
      {:ok, agent_id, state} ->
        persist(agent_id, state.name, stamped, new_index)
        state

      {:error, :not_found} ->
        Logger.warning(
          "Failed to persist message for agent #{state.name}: no agents row to attach it to"
        )

        state
    end
  end

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

  # The agent's own `agents.id`: already cached, or resolved (and
  # cached) now. See the moduledoc for why caching it is safe.
  defp agent_row_id(%{chat_state: %{agent_row_id: agent_id}} = state) when is_integer(agent_id) do
    {:ok, agent_id, state}
  end

  defp agent_row_id(state) do
    case Persistence.fetch_agent(state.space_id, state.name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        {:ok, agent_id, put_agent_row_id(state, agent_id)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp put_agent_row_id(state, agent_id) do
    %{state | chat_state: %{state.chat_state | agent_row_id: agent_id}}
  end

  # Insert then bump. A failure is logged and dropped (the in-memory
  # sequence is the runtime's source of truth), while a successful
  # INSERT is followed by the counter bump under a strict `:ok =` match
  # — a row that vanishes between the two writes fails loudly rather
  # than silently diverging the counter.
  #
  # The `:ok` clause is reachable, not dead: a malformed
  # `{:compaction, non_struct}` tuple takes the marker writer's warning
  # branch, whose `Logger.warning/1` return is `:ok`. That append is
  # dropped (no row, and nothing to bump) — the pre-existing behaviour.
  defp persist(agent_id, name, stamped, new_index) do
    case Persistence.insert_message_by_agent_id(agent_id, stamped) do
      {:ok, _row} ->
        :ok = Persistence.update_next_message_index(agent_id, new_index)

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist message for agent #{name}: #{inspect(reason)}")
    end
  end
end
