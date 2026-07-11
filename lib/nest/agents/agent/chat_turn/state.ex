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
  # `entry :: entry` carries the start-state intent for
  # this ChatTurn. An `entry` is the "what's the outstanding
  # content for this turn's first iteration?" payload,
  # structured as one of four tagged shapes:
  #
  #   * `{:user_message, User.t()}` — Trigger 1 (and the
  #     user's idle pipeline input). The user message has
  #     already been appended to `state.chat_state.messages`
  #     by the spawner (the pipeline appends; the trigger
  #     appends after the swap; the chat turn in
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
  #   * `{:compaction, System.t(), entry_or_nil}` — compactor's
  #     own chat turn. The system message (the `[mode: compact]`
  #     suffix) is at the tail of `state.chat_state.messages`.
  #     The ChatTurn's first action is to call the LLM with
  #     `tools: nil, tool_choice: :none`. When the LLM
  #     returns, the ChatTurn sends `{:compaction_done,
  #     summary_text, carried_entry}` to the Agent — NOT
  #     the normal `{:chat_idle, _}`. The third element is
  #     `nil` for Trigger A (post-turn) and the carried
  #     `{:tool_call, _, _, _}` / `{:compact_tool, _, _, _}`
  #     for Trigger B (mid-turn resume). Only 1/4 of the
  #     entry shapes are true continuations (the third
  #     element of the compactor entry, when non-nil).
  #
  # The entry is the contract — no
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
            entry: {:user_message, %Nest.Messages.User{parts: []}}

  @type tool_pair :: [Nest.Messages.Assistant.t() | Nest.Messages.Tool.t()]
  @type entry ::
          {:user_message, Nest.Messages.User.t()}
          | {:tool_call, Nest.Messages.Assistant.t(), non_neg_integer(), pos_integer()}
          | {:compact_tool, tool_pair, non_neg_integer(), pos_integer()}
          | {:compaction, Nest.Messages.System.t(), entry() | nil}
end
