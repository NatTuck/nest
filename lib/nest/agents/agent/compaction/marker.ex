defmodule Nest.Agents.Agent.Compaction.Marker do
  @moduledoc """
  Compaction marker construction.

  The marker is the boundary row the on-demand-load path
  partitions on (`agents.last_compaction_index`). It's a
  `{:compaction, %Compaction{}}` tuple carrying the
  archived count + token stats at the moment of compaction.

  Persistence and in-memory placement flow through the
  canonical paths:
    * `MessageAppender.append_history_one/2` stamps the
      marker at `state.chat_state.next_message_index`,
      appends to `history`, bumps `next_message_index`,
      and persists via `Persistence.insert_message/2`'s
      compaction clause.
    * `Nest.Agents.Agent.Broadcasts.compaction/3` carries
      the `chat:compaction` event with the marker + history.
  """

  @doc """
  Build the compaction marker struct with token counts.

  `marker_index` is consumed from `state.chat_state.next_message_index`
  before this is called — that's the slot the marker occupies
  in the combined `history ++ messages` index sequence.
  `archived_count` is the number of pre-swap messages moved
  to history. `tokens_compacted` / `tokens_compacted_to` are
  the pre/post totals (may be nil for legacy callers).
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
end
