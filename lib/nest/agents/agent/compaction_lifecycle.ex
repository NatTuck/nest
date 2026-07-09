defmodule Nest.Agents.Agent.Compaction.Lifecycle do
  @moduledoc """
  Move an agent's current `messages` list into `history` with
  a `{:compaction, _}` marker, then swap `messages` to the
  caller-supplied compacted set. Pure state transition —
  persists the marker via `Agent.Persistence` (which writes
  the marker row AND bumps `agents.last_compaction_index`
  atomically) and broadcasts the `chat:compaction` event
  (only when the DB write succeeded; on failure we log a
  warning and skip the broadcast so the UI is not told about
  a compaction that didn't actually persist).

  Also bumps `state.chat_state.last_compaction_index` to the
  new marker's index in the same state swap, so the in-memory
  partition `history ++ messages` matches `state.chat_state.last_compaction_index`'s
  derived boundary `index <= boundary` / `index > boundary`.

  Computes pre/post token totals at compaction time via
  `Nest.Tokens.Estimator.estimate_messages/1` and threads
  them into the marker struct, the DB row, and the
  `chat:compaction` broadcast payload — the UI renders them
  inside `<CollapsedHistory>`.

  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays under the 500-line credo limit.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Messages.Compaction, as: CompactionMessage
  alias Nest.Tokens.Estimator

  @doc """
  Move the agent's current `messages` to `history` (with a
  compaction marker), then replace `messages` with the new
  compacted state. The marker is a `{:compaction, _}` tuple
  that lives in `history` only — it never reaches the LLM.

  Indices are reassigned so the sequence stays monotonic and
  the LLM never sees a gap. `state.chat_state.next_message_index`
  is bumped to one past the last new compacted row so the
  next `__append_message__/2` doesn't stamp a colliding
  index below the new state. Returns the new state.
  """
  @spec apply(Nest.Agents.Agent.t(), [Nest.Messages.Message.t()]) :: Nest.Agents.Agent.t()
  def apply(state, new_messages) do
    archived_messages = state.chat_state.messages || []
    archived_count = length(archived_messages)
    marker_index = state.chat_state.next_message_index

    # Pre-tokens are summed on the un-reindexed `archived_messages`
    # list — they're the boundaries, not the post-assign indices.
    # Post-tokens are computed on the same list pre-assign because
    # `assign_indices/2` only stamps the inner-struct `index`
    # field; token estimation is shape-independent, so either
    # pre- or post-assign yields the same number. We use
    # `new_messages` for symmetry with the caller's intent
    # ("how big is the new compacted state").
    tokens_compacted = Estimator.estimate_messages(archived_messages)
    tokens_compacted_to = Estimator.estimate_messages(new_messages)

    marker =
      build_marker(marker_index, archived_count, tokens_compacted, tokens_compacted_to)

    new_state = swap_messages(state, new_messages, marker_index, marker)

    persist_and_broadcast(
      state,
      new_state,
      archived_count,
      tokens_compacted,
      tokens_compacted_to,
      marker_index,
      marker
    )

    new_state
  end

  defp build_marker(marker_index, archived_count, tokens_compacted, tokens_compacted_to) do
    {:compaction,
     %CompactionMessage{
       index: marker_index,
       archived_count: archived_count,
       tokens_compacted: tokens_compacted,
       tokens_compacted_to: tokens_compacted_to,
       occurred_at: DateTime.utc_now(),
       metadata: nil
     }}
  end

  defp swap_messages(state, new_messages, marker_index, marker) do
    # The new compacted state starts at marker_index + 1
    # (the fresh system message lands there). Bump
    # `next_message_index` to one past the last new row so
    # the next `__append_message__/2` stamp doesn't collide
    # with the new state (it would otherwise stamp at the
    # pre-swap `next_message_index`, which is below the
    # new compacted state's first row).
    assigned_new = Compaction.assign_indices(new_messages, marker_index + 1)

    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: assigned_new,
            next_message_index: marker_index + length(assigned_new) + 1,
            last_compaction_index: marker_index,
            history:
              (state.chat_state.history || []) ++
                (state.chat_state.messages || []) ++ [marker]
        }
    }
  end

  defp persist_and_broadcast(
         state,
         new_state,
         archived_count,
         tokens_compacted,
         tokens_compacted_to,
         marker_index,
         marker
       ) do
    case AgentPersistence.record_compaction(
           state.name,
           marker_index,
           archived_count,
           tokens_compacted,
           tokens_compacted_to
         ) do
      :ok ->
        Broadcasts.compaction(state.name, marker, new_state.chat_state.history)

      {:error, reason} ->
        # The in-memory state has already been swapped; the
        # live agent can continue with the compacted state.
        # But the DB is out of sync (no marker, no
        # `last_compaction_index` bump), so we MUST NOT tell
        # the client a compaction happened — its `history`
        # would diverge from the server's. Log loudly and
        # skip the broadcast.
        Logger.warning(
          "Compaction DB write failed for agent #{state.name}; " <>
            "skipping chat:compaction broadcast: #{inspect(reason)}"
        )
    end
  end
end
