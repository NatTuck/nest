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
  The *persistent* portion of a per-agent chat session — the
  fields that survive a BEAM restart and are restored from the
  DB on `build_attrs_for_start/2`.

  Per-process state (the streaming accumulator, status, API-log
  bookkeeping, compaction loop-breaker, and the user-pending /
  mid-turn resume fields) lives in `Nest.Agents.Agent.ChatState.Live`
  and is reset to defaults on every `init/1`.

  Splitting the two makes the persistence boundary explicit:
  `ChatState` is touched only by `init/1`, the restore path, and
  the append/compaction message handlers; `ChatState.Live` is
  touched by the ChatTurn, streaming, Stop, and compaction-result
  handlers. A field on the wrong side of the boundary (e.g. a
  non-nil `streaming_acc` or a preserved `crossed_thresholds`
  surviving a restart) is a bug.

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

  The `pending_children` map tracks child agents that this
  agent has spawned via `agents-spawn` (with a `query`). Keys
  are child agent IDs (strings), values are the pid of the
  blocked tool task waiting for the child's response. When a
  child completes, its GenServer sends
  `{:child_completed, child_id, response, total_usage}` to the
  parent, and the parent routes the response to the waiting
  tool task.

  The `archiving` MapSet holds the names of children spawned
  with `archive: true`. After their response is forwarded, the
  parent stops + marks them archived (one-shot spawns). Cleared
  alongside `pending_children`.

  The `read_files` map gates the `file-write` tool: every
  successful `file-read` and `file-write` is recorded here as
  `path => %{mtime: DateTime.t(), size: non_neg_integer()}`,
  taken from `File.stat/1` immediately after the tool worker
  returns. `BatchSizer.execute_one/2` consults the `:check_read_policy`
  introspection clause before any `file-write` runs and refuses
  the call with `"You must read that file before overwriting it."`
  when the path is absent, or `"File contents have changed, re-read that
  file before writing it."` when the recorded `mtime`/`size` no
  longer matches the on-disk file. Successful `file-write` calls
  overwrite the entry (so a follow-up write to the same path passes
  its own mtime check). Cleared on successful compaction
  (the LLM is summarized and shouldn't carry pre-summary reads forward)
  and on agent restart.
  """
  defstruct messages: [],
            history: [],
            last_compaction_index: -1,
            next_message_index: 0,
            pending_children: %{},
            archiving: %MapSet{},
            read_files: %{}
end

defmodule Nest.Agents.Agent.ChatState.Live do
  @moduledoc """
  The *per-process* (ephemeral) portion of a per-agent chat
  session. Every field here is reset to its default on `init/1`,
  so a BEAM restart always starts from a clean slate.

  Persisted fields live in `Nest.Agents.Agent.ChatState`; this
  struct holds only what a live turn needs while it's running.

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

  The `crossed_thresholds` field is the `MapSet` of context-usage
  threshold atoms (`:p25`, `:p50`, `:p75`) that the
  `Nest.Agents.Agent.ChatTurn.ContextReminder` has already
  announced for the current conversation segment. The ChatTurn
  fetches it via `ctx` on spawn and sends `{:set_crossed_thresholds,
  set}` back to the Agent when it fires a new threshold. Cleared
  to `%MapSet{}` on successful compaction in
  `Compaction.ResultHandler.handle_success/3`, so warnings
  re-fire if usage rises again after the history was summarized.

  The `consecutive_compaction_count` field is the loop-breaker
  counter. Incremented every time a compaction is spawned
  (Trigger B/C or `:compact` tool). Reset to 0 when a
  user/assistant/tool message is appended (genuine progress).
  When the count exceeds `@max_consecutive_compactions` in
  `Compaction.ResultHandler`, the agent enters
  `:compaction_loop_detected` and broadcasts
  `chat:compaction-loop`. The user clicks an OK button on the
  banner to clear the state and resume accepting new
  `chat:message` traffic.

  The `tool_index_map` field is the index→id map for tool-use
  streaming. Anthropic sends subsequent `input_json_delta` events
  keyed by the tool-call's `index` (not its concrete id); we
  maintain this map so the JS streaming partial can be told the
  concrete id of the call each fragment belongs to. Populated by
  the `tool_use_start` handler in `LLMStreamHandler`, reset to
  `%{}` when the streaming accumulator resets (start of a new
  LLM iteration).
  """
  defstruct streaming_acc: nil,
            status: :idle,
            active_message_index: 0,
            api_log_sequences: %{},
            pending_api_logs: %{},
            chat_turn_pid: nil,
            cancelled: false,
            pending_user_message: nil,
            mid_turn_entry: nil,
            crossed_thresholds: %MapSet{},
            consecutive_compaction_count: 0,
            tool_index_map: %{},
            # The agent's currently active conversation mode (e.g.
            # "chat", "build", "plan"). Reset to the vocation's
            # default on `init/1` and changed at runtime by the
            # mode selector / `change_mode`.
            mode: "chat"

  @type mid_turn_entry :: %{entry: Nest.Agents.Agent.ChatTurn.State.entry() | nil}
end
