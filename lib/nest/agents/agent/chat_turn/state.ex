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
  # `info :: continuation` carries the start-state intent for
  # this ChatTurn. A continuation is the "what's the
  # outstanding content for this turn's first iteration?"
  # payload, structured as one of three (or nil) shapes:
  #
  #   * `nil` — defstruct default. The ChatTurn was started
  #     without any continuation payload (legacy default;
  #     no production path passes `nil` to the spawner
  #     today; the runtime tolerates it).
  #
  #   * `{:user_message, User.t()}` — Trigger 1 (and the
  #     user's idle pipeline input). The user message has
  #     already been appended to `state.chat_state.messages`
  #     by the spawner (the pipeline appends; the compaction
  #     handler appends after the swap; the chat turn in
  #     both cases reads it from `state.chat_state.messages`).
  #     The ChatTurn's first action is to call the LLM.
  #
  #   * `{:tool_call, Assistant.t(), non_neg_integer(),
  #     pos_integer()}` — Trigger 2. The carried
  #     assistant+ToolUse is at the tail of
  #     `state.chat_state.messages`. The ChatTurn's first
  #     action is to run `execute_pending_tool_calls`
  #     (preserves iteration count via the trailing two
  #     fields).
  #
  #   * `{:compact_tool, [Assistant.t(), Tool.t()],
  #     non_neg_integer(), pos_integer()}` — Trigger 3. The
  #     carried pair [tool_call, synthetic_tool_result] is
  #     at the tail of `state.chat_state.messages`. The
  #     ChatTurn's first action falls through to the LLM
  #     (last message is a `{:tool, _}`, not a tool_call).
  #     Iteration count preserved.
  #
  # The continuation is the contract — no
  # `state.chat_state.messages`-tail inspection happens after
  # the spawner hands the messages off. The carried content
  # is placed in the active messages list at the trigger
  # site (where the swap hasn't happened yet) and carried
  # forward through the compactor's swap by the
  # `append_continuation_tail/2` helper in `CompactionHandler`.
  defstruct ctx: nil,
            iteration: 0,
            max_iterations: 0,
            force_finalize: false,
            active_worker: nil,
            active_worker_kind: nil,
            active_message_index: 0,
            crossed_thresholds: %MapSet{},
            info: nil

  @type tool_pair :: [Nest.Messages.Assistant.t() | Nest.Messages.Tool.t()]
  @type continuation ::
          nil
          | {:user_message, Nest.Messages.User.t()}
          | {:tool_call, Nest.Messages.Assistant.t(), non_neg_integer(), pos_integer()}
          | {:compact_tool, tool_pair, non_neg_integer(), pos_integer()}

  @type info :: continuation
end
