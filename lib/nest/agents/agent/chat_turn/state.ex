defmodule Nest.Agents.Agent.ChatTurn.State do
  @moduledoc false
  # The ChatTurn's State is the iteration state machine's
  # working memory. It contains ONLY iteration-scoped state
  # (counters, worker pids, the index that the next message
  # WILL be stamped with). Conversation state (messages,
  # streaming_acc, next_message_index, history, llm_metrics)
  # lives on the Agent; the ChatTurn queries via
  # GenServer.call when it needs to read, and sends events
  # for the Agent to write.
  #
  # The Agent's pid is read from `ctx.agent_pid` (ctx is
  # the per-iteration config snapshot). No duplicate field.
  #
  # `crossed_thresholds` tracks which context-usage
  # thresholds (25/50/75%) have already been announced
  # in this ChatTurn. Cleared on compaction so the
  # thresholds re-fire if usage rises again after the
  # history was summarized.
  defstruct ctx: nil,
            iteration: 0,
            max_iterations: 0,
            force_finalize: false,
            active_worker: nil,
            active_worker_kind: nil,
            active_message_index: 0,
            crossed_thresholds: %MapSet{}
end
