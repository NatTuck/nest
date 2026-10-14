defmodule Nest.Agents.Agent.ClientAPI do
  @moduledoc """
  Convenience getters extracted from `Nest.Agents.Agent`
  so the GenServer module stays under the credo 500-line
  cap. Each function is a one-line `GenServer.call` that
  forwards to the corresponding `handle_call` clause in the
  Agent's IntrospectionHandler.

  Kept in a separate module so call sites can
  `alias Nest.Agents.Agent` without pulling in the agent
  GenServer's full alias surface.

  ## Functions

    * `get_public_info/2` — full public info (name, model,
      status, modes, message_count, partial, usage).
    * `get_total_usage/2` — combined
      `usage_totals + descendant_usage` map.
    * `get_messages/2` — active message list.
    * `terminate/1` — `GenServer.stop/2` with normal reason.
    * `get_status/2` — the agent's current status, read in
      the agent's own process.

  `get_public_info/2`, `get_messages/2` and `get_total_usage/2` take the
  `GenServer.call/3` failure bound as an optional second argument. The
  default is OTP's own (5 s), which is what production callers want; a
  caller that reads state after an event — every converted `#21` test
  site — passes the suite's 1 s bound instead, so a wedged agent reports
  as a call timeout rather than as the per-test deadline (see
  `notes/sketchy-slow-tests.md` §11).

  ## Why this lives separately from IntrospectionHandler

  IntrospectionHandler owns the `handle_call` clauses; this
  module owns the "send the call" wrappers so the GenServer's
  exported call surface doesn't grow past the credo cap.
  """

  @doc """
  The agent's current status (`Nest.Agents.Agent.Machine.status_for/1`), read
  inside the agent's own process (issue #21).

  Used by the test harness's teardown, which needs to know whether the test it
  is cleaning up after ended while a turn was still running. The read is a
  message like any other, so it does not return when the agent is not there to
  answer: it exits with the reason the process went away (already stopped,
  already dying), or with `:timeout` if it never answered at all. Both mean "no
  status" — a process that cannot answer is not a process with a turn in
  flight.

  A turn runs in a worker task, not in the agent's loop, so a mid-turn agent
  answers this normally (`:streaming` / `:executing_tools` / `:compacting`).
  """
  @spec get_status(pid(), timeout()) :: atom()
  def get_status(pid, timeout) do
    GenServer.call(pid, :get_status, timeout)
  end

  @doc """
  Terminates the agent process.
  """
  @spec terminate(pid()) :: :ok
  def terminate(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Returns public information about the agent for the WebSocket protocol.

  Returns a map with :id, :model, :message_count, :status,
  :vocation_id, :partial, :parent_id, :parent_name, :depth,
  :descendant_usage, and :total_usage.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s). Pass a shorter bound when the read must fail as a call
  timeout rather than as a caller deadline.
  """
  @spec get_public_info(pid(), timeout()) :: map()
  def get_public_info(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_public_info, timeout)
  end

  @doc """
  Returns the combined usage map for the agent: `usage_totals +
  descendant_usage`, computed field-by-field.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_total_usage(pid(), timeout()) :: map() | nil
  def get_total_usage(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_total_usage, timeout)
  end

  @doc """
  Returns the parent's outstanding query children: a map of child name to
  `true` for every child still `:running` (`Machine.pending_children/1`).

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s). Pass a shorter bound when the read must fail as a call
  timeout rather than as a caller deadline.
  """
  @spec get_pending_children(pid(), timeout()) :: %{String.t() => true}
  def get_pending_children(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_pending_children, timeout)
  end

  @doc """
  Returns the context thresholds this agent has already announced
  (`live.crossed_thresholds`), as a `MapSet` of atoms.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_crossed_thresholds(pid(), timeout()) :: MapSet.t()
  def get_crossed_thresholds(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_crossed_thresholds, timeout)
  end

  @doc """
  Returns the raw children sub-machine (`Machine.Children`): the per-child
  entry map that `Children.target/2` resolves a reporting target from.
  `get_pending_children/2` is a *different* value (the `:running` names).

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_children(pid(), timeout()) :: Nest.Agents.Agent.Machine.Children.t()
  def get_children(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_children, timeout)
  end

  @doc """
  Returns the machine's turn-scoped working set (`Machine.Work`): the active
  worker and its ref, the backgrounded batches, the compaction focus.

  Read as one value on purpose: a caller that inspects several of its fields
  must see them from one snapshot, never one call per field.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_work(pid(), timeout()) :: Nest.Agents.Agent.Machine.Work.t()
  def get_work(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_work, timeout)
  end

  @doc """
  Returns the agent's LLM client configuration (`Nest.LLM.ClientConfig`): the
  client module plus the per-call opts. `get_public_info/2` deliberately omits
  it — `client` is an internal module atom the UI has no use for.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_client_config(pid(), timeout()) :: Nest.LLM.ClientConfig.t()
  def get_client_config(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_client_config, timeout)
  end

  @doc """
  Returns the agent's registered tool closures. Test-only by construction: a
  closure cannot be serialized, so this can never be a wire field.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_tools(pid(), timeout()) :: [Nest.LLM.Tool.t()]
  def get_tools(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_tools, timeout)
  end

  @doc """
  Returns the cached `Nest.Vocations.Vocation` struct the agent is running
  under. No broadcast carries it, so this is the only observation.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_vocation(pid(), timeout()) :: Nest.Vocations.Vocation.t() | nil
  def get_vocation(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_vocation, timeout)
  end

  @doc """
  Returns the outstanding watch registrations (issue #54), keyed by the
  watcher's ref: `%{pid: pid | nil, spec: term(), satisfied: boolean}`.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_watches(pid(), timeout()) :: %{reference() => map()}
  def get_watches(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_watches, timeout)
  end

  @doc """
  Returns the active message history for the agent.

  `timeout` is the `GenServer.call/3` failure bound; the default is
  OTP's (5 s).
  """
  @spec get_messages(pid(), timeout()) :: [Nest.Messages.Message.t()]
  def get_messages(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_messages, timeout)
  end

  @doc """
  Fetch the API logs for a specific message by index. For assistant
  and system messages, returns the persisted response logs. For user
  and tool messages, rebuilds the request log from conversation
  history on demand.
  """
  @spec get_api_logs(pid(), non_neg_integer(), list()) :: {:ok, [map()]} | {:error, term()}
  def get_api_logs(pid, index, history) do
    GenServer.call(pid, {:get_api_logs, index, history})
  end

  @doc """
  Register interest for a non-blocking wait (issue #54). `spec` is the watcher's
  own shape (`Nest.Agents.Agent.Watch`); the agent stores it so a Stop can kill
  the watcher and so a delivery from a watched name can satisfy it.
  """
  @spec register_watch(pid(), reference(), term()) :: :ok
  def register_watch(pid, ref, spec) do
    GenServer.call(pid, {:register_watch, ref, spec}, 5_000)
  end

  @doc "Record the watcher task's pid, once it is up."
  @spec watch_attached(pid(), reference(), pid()) :: :ok
  def watch_attached(pid, ref, task_pid) do
    GenServer.cast(pid, {:watch_attached, ref, task_pid})
  end

  @doc "Drop a watch whose watcher task could not be started."
  @spec unregister_watch(pid(), reference()) :: :ok
  def unregister_watch(pid, ref) do
    GenServer.cast(pid, {:unregister_watch, ref})
  end

  @doc """
  Deliver a fired watch's notice. Returns `:skipped` when the watch was already
  satisfied by the watched agent's own delivery (issue #62 requirement 1).
  """
  @spec watch_fired(pid(), reference(), String.t()) :: :delivered | :queued | :skipped
  def watch_fired(pid, ref, content) do
    {:ok, disposition} = GenServer.call(pid, {:watch_fired, ref, content}, 5_000)
    disposition
  end
end
