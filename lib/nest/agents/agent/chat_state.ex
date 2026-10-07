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
  touched by the in-process turn, streaming, Stop, and
  compaction-result handlers. A field on the wrong side of the
  boundary (e.g. a non-nil `streaming_acc`) is a bug.
  `crossed_thresholds` is the one Live field that is *derived* on
  restore rather than reset:
  it is rebuilt from the persisted notice metadata so a restart
  doesn't re-announce thresholds (see
  `ContextReminder.announced_thresholds/1`).

  The `last_compaction_index` field is the runtime mirror of
  the persisted `agents.last_compaction_index` column. It is
  the boundary above which rows from the persisted message
  sequence are LLM-facing. Rows at or below it are the archived
  slice, which is *derived on demand* (`Nest.Persistence.History`)
  and never held in state:

      messages = rows where message_index > last_compaction_index

  Default `-1` means "no compaction has happened; the entire
  sequence, including the system prompt at index 0, is in
  `:messages`". After the first compaction the value is the
  marker's `message_index`; the marker itself sits below the boundary
  because of the `<=` rule.

  Outstanding child agents spawned via `agents-spawn` (with a
  `query`) are tracked by the machine's
  `Nest.Agents.Agent.Machine.Children` sub-machine, not here:
  each entry carries the waiting caller's pid (the blocking tool
  worker, or the async waiter it started) and the `archive` flag,
  and transitions exactly once to a terminal state. See
  `Nest.Agents.Agent.SubAgent`.

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
            last_compaction_index: -1,
            compaction_count: 0,
            next_message_index: 0,
            read_files: %{}
end

defmodule Nest.Agents.Agent.ChatState.Live do
  @moduledoc """
  The *per-process* (ephemeral) portion of a per-agent chat
  session. Every field here is reset to its default on `init/1`,
  so a BEAM restart always starts from a clean slate.

  Persisted fields live in `Nest.Agents.Agent.ChatState`; this
  struct holds only what a live turn needs while it's running.

  The `machine` field is the `Nest.Agents.Agent.Machine` state: the
  observable kind/phase plus the turn-scoped working memory
  (`machine.work`, a `%Nest.Agents.Agent.Machine.Work{}`) the
  in-process driver (`Nest.Agents.Agent.Turn`) uses while a chat or
  compaction turn is in flight. Observable status derives from
  `Machine.status_for/1` and is never stored as a parallel field;
  `machine.work` is reset to its default at the end of every turn. The
  resume intents (`machine.pending_user_message`, `machine.mid_turn_entry`)
  and the loop-breaker (`machine.loop_count`; a count above
  `@max_consecutive_compactions` enters `:compaction_loop_detected`) live
  on the machine, not here.

  The `cancelled` field is a sticky flag set when the user
  clicks Stop. It guards the compaction resume
  so an in-flight compaction result
  does not auto-resume a new chat turn after the user has
  already stopped.

  The `crossed_thresholds` field is the `MapSet` of context-usage
  threshold atoms (`:p25`, `:p50`, `:p75`) that
  `Nest.Agents.Agent.Turn.ContextReminder` has already
  announced for the current conversation segment. Cleared
  to `%MapSet{}` on successful compaction in
  `Machine.Compaction`, so warnings
  re-fire if usage rises again after the history was summarized.
  On restore it is rebuilt from the active messages' notice
  metadata (`Init.seed_from_db/3`), so a BEAM restart mid-
  conversation does not re-announce a threshold.

  The `tool_index_map` field is the index→id map for tool-use
  streaming. Anthropic sends subsequent `input_json_delta` events
  keyed by the tool-call's `index` (not its concrete id); we
  maintain this map so the JS streaming partial can be told the
  concrete id of the call each fragment belongs to. Populated by
  the `tool_use_start` handler in `LLMStreamHandler`, reset to
  `%{}` when the streaming accumulator resets (start of a new
  LLM iteration).

  The `inbox` field holds async agent-to-agent messages that
  arrived while the agent was busy (`agents-send`). Each entry is
  `%{from: name, content: text, timestamp: DateTime.t()}`, in
  arrival order. When the agent next goes idle the entries are
  combined into a single user message (offloaded to the agent tmp
  dir when over `max-async-message-tokens`) and drained by
  `Nest.Agents.Agent.Inbox`. In-memory only: a BEAM restart drops
  undrained messages.

  The `repair` map (`%{violations: [...], command: ...}`) carries
  the `:needs_repair` payload while a restored agent's active
  sequence fails wire preflight. It is grouped here, rather than
  as two top-level fields, to keep this struct under the credo
  16-field cap.
  """
  defstruct streaming_acc: nil,
            machine: %Nest.Agents.Agent.Machine{},
            api_log_sequences: %{},
            cancelled: false,
            pending_notice: nil,
            crossed_thresholds: %MapSet{},
            # The forward-looking context size (in tokens) the most
            # recent context-warning check projected: appended messages
            # plus the pending user message and/or predicted tool-result
            # sizes. Surfaced on the status payload as
            # `usage.projected_context_input_tokens` so the UI chip can
            # show the same number the reminder compared against.
            # `nil` when no projection is in flight.
            context_projection: nil,
            tool_index_map: %{},
            # The agent's currently active conversation mode (e.g.
            # "chat", "build", "plan"). Reset to the vocation's
            # default on `init/1` and changed at runtime by the
            # mode selector / `change_mode`.
            mode: "chat",
            # Set when `Init.NeedsRepair.block/3` starts the agent in
            # the `:needs_repair` state: the active persisted sequence
            # failed wire preflight. Carries the violations and the
            # offline repair command surfaced to the operator.
            repair: %{violations: [], command: nil},
            # Async agent-to-agent messages queued while busy. See the
            # moduledoc. Entries are `%{from: name, content: text,
            # timestamp: DateTime.t()}` in arrival order.
            inbox: []
end
