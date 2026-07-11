defmodule Nest.Agents.Agent.Compaction.Marker do
  @moduledoc """
  Compaction marker construction and state swap.

  Extracted from `Nest.Agents.Agent.Compaction.ResultHandler`
  to keep that module under credo's 500-line cap.

  Owns:

    * `build_marker/4` — the `{:compaction, %Compaction{}}`
      struct with token counts.
    * `swap_messages/4` — the in-memory state swap
      (pre-swap messages → history + marker, post-swap
      messages → active list).
    * `persist_and_broadcast/7` — DB write +
      `chat:compaction` broadcast.
    * `safe_record_compaction/5` — wraps the DB write in
      a rescue (the compactor's `handle_info` runs
      outside the test sandbox and the Ecto connection
      may raise `DBConnection.OwnershipError`).
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence

  @doc """
  Build the compaction marker struct with token counts.
  """
  def build_marker(marker_index, archived_count, tokens_compacted, tokens_compacted_to) do
    {:compaction,
     %Nest.Messages.Compaction{
       index: marker_index,
       archived_count: archived_count,
       tokens_compacted: tokens_compacted,
       tokens_compacted_to: tokens_compacted_to,
       occurred_at: DateTime.utc_now(),
       metadata: nil
     }}
  end

  @doc """
  Move the agent's current `messages` to `history`
  (with a compaction marker), then replace `messages`
  with `new_messages`. Bump `last_compaction_index`
  and `next_message_index` so the in-memory state
  matches the post-swap boundaries.
  """
  def swap_messages(state, new_messages, marker_index, marker) do
    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: new_messages,
            next_message_index: marker_index + length(new_messages) + 1,
            last_compaction_index: marker_index,
            history:
              (state.chat_state.history || []) ++
                (state.chat_state.messages || []) ++ [marker]
        }
    }
  end

  @doc """
  Persist the compaction marker (atomic DB write:
  INSERT marker + UPDATE agents.last_compaction_index)
  and broadcast `chat:compaction` (carries the marker
  + full archived history). On DB failure, log and
  skip the broadcast so the client doesn't see a
  compaction that didn't persist.
  """
  def persist_and_broadcast(
        state,
        marker_index,
        marker,
        archived_count,
        tokens_compacted,
        tokens_compacted_to
      ) do
    case safe_record_compaction(
           state.name,
           marker_index,
           archived_count,
           tokens_compacted,
           tokens_compacted_to
         ) do
      :ok ->
        Broadcasts.compaction(state.name, marker, state.chat_state.history)
        state

      {:error, reason} ->
        Logger.warning(
          "Compaction DB write failed for agent #{state.name}; " <>
            "skipping chat:compaction broadcast: #{inspect(reason)}"
        )

        state
    end
  end

  # Run `record_compaction/5` and convert any
  # exception (typically a `DBConnection.OwnershipError`
  # when this runs inside `handle_info` — `$callers` is
  # unset there) into the same `{:error, reason}` shape
  # a regular failure would produce.
  defp safe_record_compaction(
         agent_name,
         marker_index,
         archived_count,
         tokens_compacted,
         tokens_compacted_to
       ) do
    AgentPersistence.record_compaction(
      agent_name,
      marker_index,
      archived_count,
      tokens_compacted,
      tokens_compacted_to
    )
  rescue
    exception -> {:error, {:persistence_exception, exception}}
  end
end
