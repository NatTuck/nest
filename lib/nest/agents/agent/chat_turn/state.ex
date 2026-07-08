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
  #
  # `info` carries the start-state intent for this ChatTurn.
  # Two shapes:
  #
  #   * `%{kind: :user_message}` — marker indicating the
  #     ChatTurn was spawned after a Trigger B compaction
  #     (or from the no-compaction `:fits` path). The user
  #     message has already been appended to the Agent's
  #     state by the chat pipeline before the spawn. The
  #     ChatTurn's first action is to call the LLM. Same
  #     dispatch as `nil` (the default); the marker exists
  #     for observability and as a sanity-check handle.
  #
  #   * `%{kind: :mid_turn, iteration, max_iterations}` —
  #     mid-turn resume after compaction. The user message
  #     and the assistant's tool-call response are already in
  #     `state.chat_state.messages`. The last message should
  #     be an assistant message with `%Part.ToolUse{}` parts;
  #     the ChatTurn's first action is to execute those tool
  #     calls rather than call the LLM. Iteration count is
  #     preserved across the compaction boundary so the
  #     tool-call iteration cap is enforced continuously.
  #
  #   * `nil` — default. Same dispatch as `:user_message`.
  defstruct ctx: nil,
            iteration: 0,
            max_iterations: 0,
            force_finalize: false,
            active_worker: nil,
            active_worker_kind: nil,
            active_message_index: 0,
            crossed_thresholds: %MapSet{},
            info: nil

  @type info ::
          %{kind: :user_message}
          | %{kind: :mid_turn, iteration: non_neg_integer(), max_iterations: pos_integer()}
          | nil
end
