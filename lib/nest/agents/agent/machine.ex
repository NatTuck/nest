defmodule Nest.Agents.Agent.Machine do
  @moduledoc """
  The Agent's single, explicit, in-process turn state machine.

  This module is the *pure* core: it owns the phase vocabulary, the
  event vocabulary, the action vocabulary, the transition function, the
  observable-status derivation, and the invariant check. `step/2` is the
  only transition function and the only turn-decision authority; it is
  dispatched by `Nest.Agents.Agent.Machine.Transitions`.

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

  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Machine.Transitions

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
    :iterate,
    :inbox_drain,
    :http_ok,
    :http_error,
    :worker_crashed,
    :worker_down,
    :worker_started,
    :llm_error,
    :append_result,
    :preflight_result,
    :stop,
    :stop_timer,
    :timer_armed,
    :compaction_request,
    :compaction_ok,
    :commit_done,
    :commit_error,
    :compaction_error,
    :retry_compaction,
    :loop_ack,
    :blocked,
    :unblocked,
    :workspace_notice,
    :tool_results,
    :child_spawned,
    :child_completed,
    :child_failed,
    :child_terminated,
    :abandon_child
  ]

  # The declared action vocabulary. Every action must have exactly one
  # `Turn.Executor` clause (pinned by `turn/executor_test.exs`).
  @actions [
    :append,
    :append_many,
    :spawn_http,
    :spawn_tools,
    :preflight,
    :stage_compaction,
    :commit_compaction,
    :kill,
    :arm_timer,
    :cancel_timer,
    :ack,
    :broadcast,
    :merge_metrics,
    :set_crossed_thresholds,
    :set_context_projection,
    :set_api_log_sequences,
    :set_cancelled,
    :set_streaming,
    :llm_error,
    :fail_turn,
    :finalize,
    :drain_inbox,
    :restore_inbox,
    :notify_worker,
    :merge_usage,
    :stop_child,
    :archive_child,
    :stop_all_children,
    :record_file_access,
    :log,
    :iterate
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

  @type action :: tuple() | :iterate

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
            mid_turn_entry: nil,
            children: %Nest.Agents.Agent.Machine.Children{},
            stop_timer: nil

  @type t :: %__MODULE__{
          kind: kind(),
          phase: phase(),
          work: Nest.Agents.Agent.Machine.Work.t(),
          entry: term(),
          resume: term(),
          loop_count: non_neg_integer(),
          pending_user_message: term(),
          mid_turn_entry: term(),
          children: Nest.Agents.Agent.Machine.Children.t(),
          stop_timer: reference() | nil
        }

  @doc "The declared phase vocabulary."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "The declared event-tag vocabulary."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "The declared action vocabulary."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc "The blocked (externally-unstuck) phases."
  @spec blocked_phases() :: [phase()]
  def blocked_phases, do: @blocked

  @doc "Build a fresh machine."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(__MODULE__, opts)

  @doc """
  The observable status, derived from `(kind, phase)`. This is the single
  authority for the Agent's observable status; nothing else may set it.
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

  @doc "True while a user stop is in flight (terminal transition pending)."
  @spec stopping?(t()) :: boolean()
  def stopping?(%__MODULE__{phase: :stopping}), do: true
  def stopping?(%__MODULE__{}), do: false

  # --- children readers ---

  @doc "The running children as a `%{name => worker_ref}` map (test/status view)."
  @spec pending_children(t()) :: %{String.t() => reference() | pid() | nil}
  def pending_children(%__MODULE__{children: %Children{children: children}}) do
    for {name, %{state: :running, worker_ref: ref}} <- children, into: %{}, do: {name, ref}
  end

  @doc "The names of currently-running children."
  @spec running_child_names(t()) :: [String.t()]
  def running_child_names(%__MODULE__{children: children}), do: Children.running_names(children)

  @doc "Drop all child bookkeeping (used by the stop/cascade paths)."
  @spec clear_children(t()) :: t()
  def clear_children(%__MODULE__{} = m), do: %{m | children: Children.new()}

  @doc """
  Apply one event. Pure: returns the actions the executor must run and the
  next machine state. Never raises for a declared event.
  """
  @spec step(t(), term()) :: {:ok, [action()], t()} | {:ignore, atom(), t()} | :quarantine
  def step(%__MODULE__{} = state, event) do
    if event_tag(event) in @events do
      Transitions.do_step(state, event)
    else
      :quarantine
    end
  end

  @doc "The tag of an event (the first tuple element, or the atom itself)."
  @spec event_tag(term()) :: atom()
  def event_tag(tag) when is_atom(tag), do: tag
  def event_tag(tuple) when is_tuple(tuple), do: elem(tuple, 0)

  @doc false
  # Test-only inverse of `status_for/1` for fixtures that need a machine in
  # a given observable status. There is no production caller; production
  # only ever reaches a phase through `step/2`.
  @spec status_to_machine(t(), atom()) :: t()
  def status_to_machine(%__MODULE__{} = m, status) do
    {kind, phase, worker_kind} = status_mapping(status)

    validate!(%{
      m
      | kind: kind,
        phase: phase,
        work: %{m.work | worker_kind: worker_kind, worker_ref: nil}
    })
  end

  defp status_mapping(:idle), do: {:chat, :idle, nil}
  defp status_mapping(:streaming), do: {:chat, :generating, :http}
  defp status_mapping(:executing_tools), do: {:chat, :executing_tools, :tools}
  defp status_mapping(:compacting), do: {:compaction, :generating, :http}
  defp status_mapping(status), do: {:chat, status, nil}

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
