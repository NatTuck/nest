defmodule Nest.Agents.Agent.Machine do
  @moduledoc """
  The Agent's single, explicit, in-process turn state machine.

  This module is the *pure* core: it owns the phase vocabulary, the
  event vocabulary, the transition function, the observable-status
  derivation, and the invariant check. The Agent process is the
  executor: it calls `step/2`, applies the returned actions (which are
  the only side-effecting operations), and holds the authoritative
  machine state.

  ## Observable vs internal state

  Anything observable (the UI, other agents, the channel/protocol) is
  explicit state here and is *derived* from `(kind, phase)` via
  `status_for/1` — never mirrored. Purely internal working set
  (`worker_ref`, `iteration`, `entry`) is allowed to be opaque.

  ## Kinds and phases

  `kind` is `:chat` or `:compaction`. A chat turn alternates
  `:generating` (an LLM call is in flight) and `:executing_tools` (a
  tool worker is in flight). A compaction is `:generating` then
  `:committing`. `:stopping` is the terminal-preemption phase. The
  blocked phases are user-actionable stalls.

  ## Drift protection

  The behavior contract for this module lives in its tests, not in this
  moduledoc (see `test/nest/agents/agent/machine_test.exs`). Per-behavior
  intent is recorded there as inline `#` comments adjacent to the
  assertion, so a line-range read of the code cannot see the code without
  the intent. This moduledoc carries no transition table.

  `step/2` returns:

    * `{:ok, actions, new_state}` — a defined transition
    * `{:ignore, reason, state}` — a declared event with intentionally
      no effect in this phase
    * `:quarantine` — an undeclared event tag (drift)
  """

  # The blocked phases are terminal-ish stalls that require an external
  # action (change model, repair, retry, acknowledge) to leave.
  @blocked [
    :needs_repair,
    :model_missing,
    :context_overflow,
    :compaction_failed,
    :compaction_loop_detected
  ]

  @phases [:idle, :generating, :executing_tools, :committing, :stopping | @blocked]

  # The declared event vocabulary. A tag not in this list is quarantined
  # by `step/2`; a tag in this list must be classified for every phase by
  # the transition-coverage test.
  @events [
    :chat_request,
    :http_ok,
    :http_error,
    :worker_crashed,
    :worker_down,
    :tool_results,
    :stop,
    :stop_timer,
    :compaction_request,
    :compaction_ok,
    :compaction_error,
    :child_completed,
    :child_failed,
    :child_terminated,
    :abandon_child,
    :inbox_drain,
    :retry_compaction,
    :loop_ack
  ]

  @type kind :: :chat | :compaction

  @type phase ::
          :idle
          | :generating
          | :executing_tools
          | :committing
          | :stopping
          | :needs_repair
          | :model_missing
          | :context_overflow
          | :compaction_failed
          | :compaction_loop_detected

  @type action ::
          {:append, term()}
          | {:persist, term()}
          | {:broadcast, atom(), term()}
          | {:spawn_http, term()}
          | {:spawn_tools, term()}
          | {:kill, reference()}
          | {:arm_timer, pos_integer()}
          | {:cancel_timer, reference()}
          | {:spawn_child, term()}
          | {:notify_parent, term()}

  @type tool_pair :: [Nest.Messages.Assistant.t() | Nest.Messages.Tool.t()]

  # The start-state intent for a turn's first iteration. See
  # `Nest.Agents.Agent.Turn` for the per-shape behavior.
  @type entry ::
          {:user_message, Nest.Messages.User.t()}
          | {:tool_call, Nest.Messages.Assistant.t(), non_neg_integer(), pos_integer()}
          | {:compact_tool, tool_pair(), non_neg_integer(), pos_integer()}
          | {:assistant_response, Nest.Messages.Assistant.t(), non_neg_integer(), pos_integer()}
          | {:compaction, [tuple()], entry() | nil}

  defstruct kind: :chat,
            phase: :idle,
            work: %Nest.Agents.Agent.Machine.Work{},
            entry: nil,
            resume: nil,
            loop_count: 0,
            pending_user_message: nil,
            mid_turn_entry: nil

  @type t :: %__MODULE__{
          kind: kind(),
          phase: phase(),
          work: Nest.Agents.Agent.Machine.Work.t(),
          entry: term(),
          resume: term(),
          loop_count: non_neg_integer(),
          pending_user_message: term(),
          mid_turn_entry: term()
        }

  @doc "The declared phase vocabulary."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "The declared event-tag vocabulary."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "The blocked (externally-unstuck) phases."
  @spec blocked_phases() :: [phase()]
  def blocked_phases, do: @blocked

  @doc "Build a fresh machine."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(__MODULE__, opts)

  @doc """
  The observable status, derived from `(kind, phase)`. This is the single
  authority for the Agent's `live.status`; nothing else may set it.
  """
  @spec status_for(t()) :: atom()
  def status_for(%__MODULE__{phase: p}) when p in @blocked, do: p
  def status_for(%__MODULE__{phase: :idle}), do: :idle
  def status_for(%__MODULE__{phase: :executing_tools}), do: :executing_tools
  def status_for(%__MODULE__{phase: :generating, kind: :chat}), do: :streaming
  def status_for(%__MODULE__{phase: :generating, kind: :compaction}), do: :compacting
  def status_for(%__MODULE__{phase: :committing}), do: :compacting
  def status_for(%__MODULE__{phase: :stopping, kind: :chat}), do: :streaming
  def status_for(%__MODULE__{phase: :stopping, kind: :compaction}), do: :compacting

  # --- runtime transitions ---
  #
  # The executor drives these; each is the runtime equivalent of a
  # modeled `step/2` transition. The invariant is enforced on entry, and
  # `status_for/1` is the single authority for the observable status.

  @doc "Terminal transition back to idle (clears the working set)."
  @spec to_idle(t()) :: t()
  def to_idle(%__MODULE__{} = s), do: validate!(%{s | phase: :idle, work: %__MODULE__.Work{}})

  @doc "A chat turn's LLM call is in flight."
  @spec to_chat_generating(t()) :: t()
  def to_chat_generating(%__MODULE__{} = s), do: put(s, :chat, :generating, :http)

  @doc "A chat turn's tool worker is in flight."
  @spec to_chat_tools(t()) :: t()
  def to_chat_tools(%__MODULE__{} = s), do: put(s, :chat, :executing_tools, :tools)

  @doc "A compaction summary call is in flight."
  @spec to_compaction_generating(t()) :: t()
  def to_compaction_generating(%__MODULE__{} = s), do: put(s, :compaction, :generating, :http)

  @doc "A compaction summary landed and is being committed."
  @spec to_compaction_committing(t()) :: t()
  def to_compaction_committing(%__MODULE__{} = s), do: put(s, :compaction, :committing)

  @doc "Enter a blocked (externally-unstuck) phase."
  @spec to_blocked(t(), phase()) :: t()
  def to_blocked(%__MODULE__{} = s, phase) when phase in @blocked, do: put(s, s.kind, phase)

  # Inverse of `status_for/1` for callers that legitimately start from an
  # observable status (tests simulating a phase). Kept alongside the
  # authority so the mapping can't drift.
  @doc false
  @spec status_to_machine(t(), atom()) :: t()
  def status_to_machine(%__MODULE__{} = s, status) do
    case status do
      :idle -> to_idle(s)
      :streaming -> to_chat_generating(s)
      :executing_tools -> to_chat_tools(s)
      :compacting -> to_compaction_generating(s)
      other -> to_blocked(s, other)
    end
  end

  defp put(%__MODULE__{} = s, kind, phase, worker_kind \\ nil) do
    validate!(%{
      s
      | kind: kind,
        phase: phase,
        work: %{s.work | worker_kind: worker_kind, worker_ref: nil}
    })
  end

  @doc """
  Apply one event. Pure: returns the actions the executor must run and the
  next machine state. Never raises for a declared event.
  """
  @spec step(t(), term()) :: {:ok, [action()], t()} | {:ignore, atom(), t()} | :quarantine
  def step(%__MODULE__{} = state, event) do
    if event_tag(event) in @events do
      do_step(state, event)
    else
      :quarantine
    end
  end

  @doc "The tag of an event (the first tuple element, or the atom itself)."
  @spec event_tag(term()) :: atom()
  def event_tag(tag) when is_atom(tag), do: tag
  def event_tag(tuple) when is_tuple(tuple), do: elem(tuple, 0)

  # --- transitions ---
  #
  # NOTE: intentional behavior for each non-obvious clause is recorded as
  # an inline comment next to the clause *and* pinned by a test in
  # machine_test.exs. Do not move intent into @doc.

  # idle is the only phase that accepts new work.
  defp do_step(%{phase: :idle} = s, {:chat_request, _} = e) do
    {:ok, [{:append_user, e}, {:spawn_http, e}],
     %{s | kind: :chat, phase: :generating, work: %{s.work | worker_kind: :http}}}
  end

  defp do_step(%{phase: :idle} = s, {:inbox_drain, _} = e) do
    {:ok, [{:append_user, e}, {:spawn_http, e}],
     %{s | kind: :chat, phase: :generating, work: %{s.work | worker_kind: :http}}}
  end

  # A chat LLM response with tool calls moves to tool execution; a text
  # response finalizes the turn back to idle.
  defp do_step(%{phase: :generating, kind: :chat} = s, {:http_ok, %{tool_calls: [_ | _]} = e}) do
    {:ok, [{:append_assistant, e}, {:spawn_tools, e}],
     %{s | phase: :executing_tools, work: %{s.work | worker_kind: :tools, worker_ref: nil}}}
  end

  defp do_step(%{phase: :generating, kind: :chat} = s, {:http_ok, e}) do
    {:ok, [{:append_assistant, e}, :finalize_idle],
     %{s | phase: :idle, work: %{s.work | worker_kind: nil, worker_ref: nil}}}
  end

  # Tool results feed back into the LLM.
  defp do_step(%{phase: :executing_tools} = s, {:tool_results, e}) do
    {:ok, [{:append_tools, e}, {:spawn_http, e}],
     %{
       s
       | phase: :generating,
         work: %{s.work | worker_kind: :http, worker_ref: nil, iteration: s.work.iteration + 1}
     }}
  end

  # A mid-turn request to compact switches the turn to the compaction kind.
  defp do_step(%{phase: p} = s, {:compaction_request, e})
       when p in [:generating, :executing_tools] do
    {:ok, [{:stage_compaction, e}, {:spawn_http, e}],
     %{
       s
       | kind: :compaction,
         phase: :generating,
         work: %{s.work | worker_kind: :http, worker_ref: nil},
         resume: e
     }}
  end

  # Compaction summary lands: commit, then resume the carried entry.
  defp do_step(%{phase: :generating, kind: :compaction} = s, {:compaction_ok, e}) do
    {:ok, [{:commit_compaction, e}, {:resume, s.resume}],
     %{
       s
       | kind: :chat,
         phase: :idle,
         work: %{s.work | worker_kind: nil, worker_ref: nil},
         resume: nil
     }}
  end

  # Stop preempts any active phase. The worker kind is cleared (the phase
  # is no longer waiting on that kind); the worker ref is kept so the
  # executor can signal the in-flight task to stop.
  defp do_step(%{phase: p} = s, {:stop, _}) when p in [:generating, :executing_tools] do
    {:ok, [{:kill, s.work.worker_ref}, {:arm_timer, 2_000}],
     %{s | phase: :stopping, work: %{s.work | worker_kind: nil}}}
  end

  # A late worker result after stop is intentionally dropped, not appended.
  # The terminal recovery already closed the sequence; appending would
  # orphan the result. Do not "repair" this by appending.
  defp do_step(%{phase: :stopping} = s, {:http_ok, _}), do: {:ignore, :late_result_after_stop, s}

  defp do_step(%{phase: :stopping} = s, {:tool_results, _}),
    do: {:ignore, :late_result_after_stop, s}

  # The stop fallback timer force-finalizes.
  defp do_step(%{phase: :stopping} = s, :stop_timer) do
    {:ok, [:force_finalize],
     %{s | phase: :idle, work: %{s.work | worker_kind: nil, worker_ref: nil}}}
  end

  # A duplicate result for a phase that is no longer waiting is a no-op.
  defp do_step(%{phase: :idle} = s, {:http_ok, _}), do: {:ignore, :stale_result, s}
  defp do_step(%{phase: :idle} = s, {:tool_results, _}), do: {:ignore, :stale_result, s}

  # Child lifecycle events are handled by the Children sub-machine; from
  # the turn machine's perspective they never change the phase.
  defp do_step(%{phase: p} = s, {:child_completed, _}) when p not in @blocked,
    do: {:ignore, :children_submachine, s}

  defp do_step(%{phase: _} = s, {:child_failed, _}), do: {:ignore, :children_submachine, s}
  defp do_step(%{phase: _} = s, {:child_terminated, _}), do: {:ignore, :children_submachine, s}
  defp do_step(%{phase: _} = s, {:abandon_child, _}), do: {:ignore, :children_submachine, s}

  # Blocked phases reject ordinary work until an external action unsticks
  # them; the retry/ack events are their only exits.
  defp do_step(%{phase: p} = s, _event) when p in @blocked, do: {:ignore, :blocked, s}

  # Any declared event not matched above is intentionally inert here.
  defp do_step(%__MODULE__{} = s, _event), do: {:ignore, :not_applicable, s}

  @doc """
  Assert the machine's cross-field invariants. Raises on violation.

  Invariants:
    * a `:generating`/`:executing_tools` phase has a `worker_kind`; idle,
      committing, stopping and blocked phases have `worker_kind == nil`;
    * an `:executing_tools` phase is only ever `:chat`;
    * a `:committing` phase is only ever `:compaction`;
    * `kind` is `:chat` or `:compaction`.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{kind: k} = s) when k in [:chat, :compaction] do
    validate_worker!(s)
    validate_kind!(s)
    s
  end

  defp validate_worker!(%{phase: p, work: %{worker_kind: wk}})
       when p in [:generating, :executing_tools] do
    if wk in [:http, :tools],
      do: :ok,
      else: raise("machine invariant: #{p} needs a worker_kind, got #{inspect(wk)}")
  end

  defp validate_worker!(%{phase: p, work: %{worker_kind: wk}})
       when p in [:idle, :committing, :stopping] or p in @blocked do
    if is_nil(wk),
      do: :ok,
      else: raise("machine invariant: #{p} must not have a worker_kind, got #{inspect(wk)}")
  end

  defp validate_kind!(%{phase: :executing_tools, kind: :chat}), do: :ok

  defp validate_kind!(%{phase: :executing_tools, kind: k}),
    do: raise("machine invariant: :executing_tools is chat-only, got #{inspect(k)}")

  defp validate_kind!(%{phase: :committing, kind: :compaction}), do: :ok

  defp validate_kind!(%{phase: :committing, kind: k}),
    do: raise("machine invariant: :committing is compaction-only, got #{inspect(k)}")

  defp validate_kind!(_), do: :ok
end
