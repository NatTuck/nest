defmodule Nest.Agents.Agent.Compaction.Lifecycle do
  @moduledoc """
  Move an agent's current `messages` list into `history` with
  a `{:compaction, _}` marker, then swap `messages` to the
  caller-supplied compacted set. Pure state transition —
  persists the archive via `Agent.Persistence` and broadcasts
  the `chat:compaction` event.

  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays under the 500-line credo limit.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Messages.Compaction, as: CompactionMessage

  @doc """
  Move the agent's current `messages` to `history` (with a
  compaction marker), then replace `messages` with the new
  compacted state. The marker is a `{:compaction, _}` tuple
  that lives in `history` only — it never reaches the LLM.

  Indices are reassigned so the sequence stays monotonic and
  the LLM never sees a gap. Returns the new state.
  """
  @spec apply(Nest.Agents.Agent.t(), [Nest.Messages.Message.t()]) :: Nest.Agents.Agent.t()
  def apply(state, new_messages) do
    archived_count = length(state.chat_state.messages || [])
    marker_index = state.chat_state.next_message_index

    marker = build_marker(marker_index, archived_count)
    new_state = swap_messages(state, new_messages, marker_index, new_messages, marker)
    persist_and_broadcast(state, new_state, archived_count, marker_index, marker)
    new_state
  end

  defp build_marker(marker_index, archived_count) do
    {:compaction,
     %CompactionMessage{
       index: marker_index,
       archived_count: archived_count,
       occurred_at: DateTime.utc_now(),
       metadata: nil
     }}
  end

  defp swap_messages(state, new_messages, marker_index, _new_messages_full, marker) do
    # The new compacted state starts at marker_index + 1.
    assigned_new = Compaction.assign_indices(new_messages, marker_index + 1)

    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: assigned_new,
            history:
              (state.chat_state.history || []) ++
                (state.chat_state.messages || []) ++ [marker]
        }
    }
  end

  defp persist_and_broadcast(state, new_state, archived_count, marker_index, marker) do
    first_index = compute_first_index(new_state.chat_state.history || [], marker_index)
    AgentPersistence.archive_and_compact(state.id, first_index, marker_index, archived_count)
    Broadcasts.compaction(state.id, marker, new_state.chat_state.history)
  end

  # Returns the index of the first archived message after the
  # current `messages` were moved to `history`. Falls back to
  # `marker_index` (which becomes the compaction row's index)
  # when no messages were archived.
  defp compute_first_index(history, marker_index) do
    case Enum.reverse(history)
         |> Enum.find(fn
           {:compaction, _} -> false
           _ -> true
         end) do
      nil -> marker_index
      {_, %{index: idx}} -> idx
    end
  end
end
