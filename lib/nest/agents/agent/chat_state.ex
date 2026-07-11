defmodule Nest.Agents.Agent.LlmMetrics do
  @moduledoc """
  LLM call metrics and the resolved context limit. Lives in a
  sub-struct so the `Agent` struct stays focused on identity
  and configuration.

  `descendant_usage` tracks the cumulative token usage from all
  descendant agents (children, grandchildren, etc.). It has the
  same session-sum fields as `usage_totals`. The `total_usage`
  is computed as `usage_totals + descendant_usage`.
  """
  defstruct context_limit: nil,
            context_limit_source: nil,
            usage_totals: nil,
            descendant_usage: nil
end

defmodule Nest.Agents.Agent.ChatState do
  @moduledoc """
  Per-agent chat operation state. Holds the live and archived
  message histories, the streaming accumulator, status, and
  API-log bookkeeping. Lives in a sub-struct so the `Agent`
  struct stays focused on identity and configuration.

  The `chat_turn_pid` field tracks the in-flight ChatTurn
  GenServer child that is currently driving the LLM call
  chain for this agent. It is set when the ChatTurn is
  spawned (in `ChatPipeline.spawn_chat_turn/1`) and cleared
  on natural completion or after a user-initiated stop. The
  stop handler reads it to send a `{:stop_chat, _}` signal.

  The `cancelled` field is a sticky flag set when the user
  clicks Stop. It guards the `compaction_done` /
  `chat_continuation` branch so an in-flight compaction result
  does not auto-resume a new chat turn after the user has
  already stopped.

  The `pending_children` map tracks child agents that this
  agent has spawned via `clone_agent`. Keys are child agent
  IDs (strings), values are the pid of the blocked tool task
  waiting for the child's response. When a child completes,
  its GenServer sends `{:child_completed, child_id, response, total_usage}`
  to the parent, and the parent routes the response to the
  waiting tool task.

  The `pending_user_message` field holds the user's incoming
  message — `{content, mode}` — until we know whether compaction
  fires. `handle_chat/3` stores the message here and runs the
  preflight; if preflight fits, the field is consumed by
  `handle_chat/3`'s append path. If preflight needs compaction,
  the field is preserved across the compaction; on success, the
  compaction handler's `chat_continuation` branch appends it
  via `ChatPipeline.resume_with_pending/1`. On failure, the
  field stays set so `chat:retry-compaction` can re-attach it
  to the next compaction attempt.

  The `mid_turn_entry` field is set when a mid-turn
  compaction is in flight or has failed. Its presence tells
  `retry_compaction/1` to resume with `:mid_turn_entry`
  (spawn a fresh ChatTurn to execute the LLM's pending tool
  calls) instead of the Trigger B path (append a held user
  message). It carries the entry (the resume payload for
  the next ChatTurn) so the tool-call iteration cap is
  enforced across the compaction boundary.

  The `last_compaction_index` field is the runtime mirror of
  the persisted `agents.last_compaction_index` column. It is
  the boundary that decides which rows from the persisted
  message sequence land in `:history` and which land in
  `:messages`:

      messages = rows where message_index > last_compaction_index
      history  = rows where message_index <= last_compaction_index

  Default `-1` means "no compaction has happened; the entire
  sequence, including the system prompt at index 0, is in
  `:messages`". After the first compaction the value is the
  marker's `message_index`; the marker itself sits in `:history`
  because of the `<=` rule.
  """
  defstruct messages: [],
            history: [],
            last_compaction_index: -1,
            next_message_index: 0,
            streaming_acc: nil,
            status: :idle,
            active_message_index: 0,
            api_log_sequences: %{},
            pending_api_logs: %{},
            chat_turn_pid: nil,
            cancelled: false,
            pending_children: %{},
            pending_user_message: nil,
            mid_turn_entry: nil,
            # Loop-breaker counter. Incremented every time a
            # compaction is spawned (Trigger B/C or `:compact`
            # tool). Reset to 0 when a user/assistant/tool message
            # is appended (genuine progress). When the count
            # exceeds `@max_consecutive_compactions` in
            # `Compaction.ResultHandler`, the agent enters
            # `:compaction_loop_detected` and broadcasts
            # `chat:compaction-loop`. The user clicks an OK
            # button on the banner to clear the state and
            # resume accepting new `chat:message` traffic.
            consecutive_compaction_count: 0

  @type mid_turn_entry :: %{entry: Nest.Agents.Agent.ChatTurn.State.entry() | nil}
end
