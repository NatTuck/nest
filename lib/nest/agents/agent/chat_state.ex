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

  The `mid_turn_compaction` field is set when a mid-turn
  compaction is in flight or has failed. Its presence tells
  `retry_compaction/1` to resume with `:mid_turn_continuation`
  (spawn a fresh ChatTurn to execute the LLM's pending tool
  calls) instead of the Trigger B path (append a held user
  message). It carries the iteration count and max-iterations
  so the tool-call iteration cap is enforced across the
  compaction boundary.
  """
  defstruct messages: [],
            history: [],
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
            mid_turn_compaction: nil

  @type mid_turn_compaction ::
          %{iteration: non_neg_integer(), max_iterations: pos_integer()}
end
