defmodule Nest.Agents.Agent.Machine.Children do
  @moduledoc """
  Pure sub-machine for a parent agent's outstanding query children.

  Each child the parent spawns with a `query` is tracked here as
  `state: :running`, then transitions exactly once to a terminal state:
  `:completed`, `:failed`, `:abandoned`, or `:terminated`. Later events for
  a terminal (or unknown) child are no-ops, which makes the parent's
  routing of `:child_completed` / `:child_failed` / `:child_terminated` /
  `:abandon_child` idempotent regardless of arrival order.

  A terminal transition's action is `{:child_message, name, result}`: the
  executor delivers it, in the parent's own process, so a child worker that is
  already gone cannot lose the result (issue #31 §2.1). Delivery goes to the
  child's *reporting target* — the parent's own inbox by default, or the batch
  coordinator that spawned it — and falls back to the parent's inbox when that
  target is no longer alive.

  This module is pure; the Agent executes the returned actions.
  """

  @terminal [:completed, :failed, :abandoned, :terminated]

  defstruct children: %{}

  @type state :: :running | :completed | :failed | :abandoned | :terminated

  @type entry :: %{
          state: state(),
          result: term(),
          usage: term(),
          archive: boolean(),
          target: pid() | nil
        }

  @type t :: %__MODULE__{children: %{String.t() => entry()}}

  @doc "A fresh, empty children sub-machine."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The child's state, or `:unknown`."
  @spec status(t(), String.t()) :: state() | :unknown
  def status(%__MODULE__{children: c}, name) do
    case c[name] do
      %{state: s} -> s
      nil -> :unknown
    end
  end

  @doc "True when the child is currently running."
  @spec running?(t(), String.t()) :: boolean()
  def running?(m, name), do: status(m, name) == :running

  @doc "The names of currently-running children."
  @spec running_names(t()) :: [String.t()]
  def running_names(%__MODULE__{children: c}) do
    for {name, %{state: :running}} <- c, do: name
  end

  @doc """
  Register a freshly-spawned child as running. (`register/3`, not `spawn/3`: the
  name would collide with `Kernel.spawn/3`.)

  `archive` records whether the parent asked for a one-shot child
  (`agents-spawn`/`agents-batch` with `archive: true`): a completed
  child is archived exactly once, at its terminal transition.
  """
  @spec register(t(), String.t()) :: {:ok, [term()], t()} | {:ignore, atom(), t()}
  def register(m, name), do: register(m, name, false, nil)

  @spec register(t(), String.t(), boolean()) :: {:ok, [term()], t()} | {:ignore, atom(), t()}
  def register(m, name, archive), do: register(m, name, archive, nil)

  @doc """
  Register a child, optionally with a **reporting target**: the pid its terminal
  transition reports to.

  `nil` (the default) means the parent's own inbox — what a plain
  `agents-spawn` does. A batch passes its coordinator, so the parent reads the
  batch's aggregate once instead of every child's answer as well; if that
  coordinator is gone by then, the outcome falls back to the parent's inbox, so
  a dead coordinator degrades to per-child messages rather than to silence. (A
  spawn request that is still in flight when the parent's Stop lands is refused
  while the parent is `:stopping`, so a stopped batch cannot spawn a child that
  reports to the coordinator the stop just killed. The refusal is phase-scoped,
  so a request arriving *after* the stop completes is accepted — see the known
  residual in `BatchCoordinator`.)
  """
  @spec register(t(), String.t(), boolean(), pid() | nil) ::
          {:ok, [term()], t()} | {:ignore, atom(), t()}
  def register(%__MODULE__{} = m, name, archive, target) do
    if Map.has_key?(m.children, name) do
      {:ignore, :duplicate_child, m}
    else
      entry = %{state: :running, result: nil, usage: nil, archive: archive, target: target}

      {:ok, [], put(m, name, entry)}
    end
  end

  @doc """
  True when `pid` is the reporting target of a child this parent is tracking.

  Used by the parent's `:DOWN` handling: a batch coordinator that dies before
  its aggregate leaves a batch that will never complete, and the parent is told
  rather than left waiting.
  """
  @spec reporting_target?(t(), term()) :: boolean()
  def reporting_target?(%__MODULE__{children: c}, pid) when is_pid(pid) do
    Enum.any?(c, fn {_name, entry} -> entry.target == pid end)
  end

  def reporting_target?(_m, _pid), do: false

  @doc """
  The distinct pids this parent's children report to, in name order.

  Used by the stop transition: a Stop must reach the batch coordinators too. A
  coordinator is an unlinked task, so killing only the turn's own worker would
  leave it spawning children and later delivering an aggregate the stopped
  parent never asked for. A *terminal* child's target is included as well — the
  coordinator is still the batch's reporting target until it delivers, and the
  batch is not over before then.

  Name order makes the emitted kill actions deterministic.
  """
  @spec reporting_targets(t()) :: [pid()]
  def reporting_targets(%__MODULE__{children: c}) do
    c
    |> Enum.sort_by(fn {name, _entry} -> name end)
    |> Enum.map(fn {_name, entry} -> entry.target end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  The pid a child's outcome is reported to, or `nil` for the parent's own inbox.
  """
  @spec target(t(), String.t()) :: pid() | nil
  def target(%__MODULE__{children: c}, name) do
    case c[name] do
      %{target: target} -> target
      nil -> nil
    end
  end

  @doc "Apply one child lifecycle event."
  @spec step(t(), term()) :: {:ok, [term()], t()} | {:ignore, atom(), t()}
  def step(%__MODULE__{} = m, {:completed, name, response, usage}) do
    terminal(m, name, :completed, response, usage, [
      {:child_message, name, {:ok, response}},
      {:merge_usage, name, usage}
    ])
  end

  def step(%__MODULE__{} = m, {:failed, name, reason}) do
    terminal(m, name, :failed, reason, nil, [{:child_message, name, {:failed, reason}}])
  end

  def step(%__MODULE__{} = m, {:terminated, name, reason}) do
    terminal(m, name, :terminated, reason, nil, [{:child_message, name, {:terminated, reason}}])
  end

  def step(%__MODULE__{} = m, {:abandoned, name}) do
    terminal(m, name, :abandoned, nil, nil, [{:stop_child, name}])
  end

  def step(%__MODULE__{} = m, _other), do: {:ignore, :not_applicable, m}

  # Exactly one terminal transition wins. Once terminal, a later event is a
  # no-op, so a completion racing a stop cannot deliver two messages.
  #
  # intentional: an `:abandoned` child that nonetheless completes later does
  # NOT merge usage. The user asked to stop everything, so the child's cost
  # is intentionally not counted. Do not "fix" this by merging.
  #
  # intentional: an `:abandoned` child gets NO message. The parent's own tool
  # asked for that stop (a batch per-item deadline, or the parent's Stop), so a
  # runtime notice would be telling the parent something it just did — the tool
  # reports the slot itself. A child that dies on its own is the case the parent
  # did not ask for, and that one does get a `{:terminated, …}` message.
  #
  # intentional: archiving is a completion-only concern. A completed child
  # spawned with `archive: true` emits exactly one `{:archive_child, name}`;
  # a failed/terminated/abandoned child never does. Do not archive on
  # failure — a crashed child is left in place for inspection.
  defp terminal(m, name, term_state, result, usage, actions) do
    case m.children[name] do
      %{state: s} when s in @terminal ->
        {:ignore, :already_terminal, m}

      %{archive: archive, target: target} ->
        actions =
          if archive and term_state == :completed,
            do: actions ++ [{:archive_child, name}],
            else: actions

        entry = %{
          state: term_state,
          result: result,
          usage: usage,
          archive: archive,
          target: target
        }

        {:ok, actions, put(m, name, entry)}

      nil ->
        {:ignore, :unknown_child, m}
    end
  end

  defp put(m, name, entry), do: %{m | children: Map.put(m.children, name, entry)}
end
