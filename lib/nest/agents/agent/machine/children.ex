defmodule Nest.Agents.Agent.Machine.Children do
  @moduledoc """
  Pure sub-machine for a parent agent's outstanding query children.

  Each child the parent spawns with a `query` is tracked here as
  `state: :running`, then transitions exactly once to a terminal state:
  `:completed`, `:failed`, `:abandoned`, or `:terminated`. Later events for
  a terminal (or unknown) child are no-ops, which makes the parent's
  routing of `:child_completed` / `:child_failed` / `:child_terminated` /
  `:abandon_child` idempotent regardless of arrival order.

  This module is pure; the Agent executes the returned actions.
  """

  @terminal [:completed, :failed, :abandoned, :terminated]

  defstruct children: %{}

  @type state :: :running | :completed | :failed | :abandoned | :terminated

  @type entry :: %{
          state: state(),
          worker_ref: reference() | pid() | nil,
          result: term(),
          usage: term(),
          archive: boolean()
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
  Register a freshly-spawned child as running.

  `archive` records whether the parent asked for a one-shot child
  (`agents-spawn`/`agents-batch` with `archive: true`): a completed
  child is archived exactly once, at its terminal transition.
  """
  @spec spawn(t(), String.t(), reference() | pid() | nil) ::
          {:ok, [term()], t()} | {:ignore, atom(), t()}
  def spawn(m, name, worker_ref), do: spawn(m, name, worker_ref, false)

  @spec spawn(t(), String.t(), reference() | pid() | nil, boolean()) ::
          {:ok, [term()], t()} | {:ignore, atom(), t()}
  def spawn(%__MODULE__{} = m, name, worker_ref, archive) do
    if Map.has_key?(m.children, name) do
      {:ignore, :duplicate_child, m}
    else
      entry = %{
        state: :running,
        worker_ref: worker_ref,
        result: nil,
        usage: nil,
        archive: archive
      }

      {:ok, [{:track_child, name, worker_ref}], put(m, name, entry)}
    end
  end

  @doc "Apply one child lifecycle event."
  @spec step(t(), term()) :: {:ok, [term()], t()} | {:ignore, atom(), t()}
  def step(%__MODULE__{} = m, {:completed, name, response, usage}) do
    terminal(m, name, :completed, response, usage, [
      {:notify_worker, name, {:ok, response}},
      {:merge_usage, name, usage}
    ])
  end

  def step(%__MODULE__{} = m, {:failed, name, reason}) do
    terminal(m, name, :failed, reason, nil, [{:notify_worker, name, {:error, reason}}])
  end

  def step(%__MODULE__{} = m, {:terminated, name, reason}) do
    terminal(m, name, :terminated, reason, nil, [{:notify_worker, name, {:error, reason}}])
  end

  def step(%__MODULE__{} = m, {:abandoned, name}) do
    terminal(m, name, :abandoned, nil, nil, [{:stop_child, name}])
  end

  def step(%__MODULE__{} = m, _other), do: {:ignore, :not_applicable, m}

  # Exactly one terminal transition wins. Once terminal, a later event is a
  # no-op, so a completion racing a stop cannot double-notify the worker.
  #
  # intentional: an `:abandoned` child that nonetheless completes later does
  # NOT merge usage. The user asked to stop everything, so the child's cost
  # is intentionally not counted. Do not "fix" this by merging.
  #
  # intentional: archiving is a completion-only concern. A completed child
  # spawned with `archive: true` emits exactly one `{:archive_child, name}`;
  # a failed/terminated/abandoned child never does. Do not archive on
  # failure — a crashed child is left in place for inspection.
  defp terminal(m, name, term_state, result, usage, actions) do
    case m.children[name] do
      %{state: s} when s in @terminal ->
        {:ignore, :already_terminal, m}

      %{archive: archive} ->
        actions =
          if archive and term_state == :completed,
            do: actions ++ [{:archive_child, name}],
            else: actions

        entry = %{
          state: term_state,
          worker_ref: nil,
          result: result,
          usage: usage,
          archive: archive
        }

        {:ok, actions, put(m, name, entry)}

      nil ->
        {:ignore, :unknown_child, m}
    end
  end

  defp put(m, name, entry), do: %{m | children: Map.put(m.children, name, entry)}
end
