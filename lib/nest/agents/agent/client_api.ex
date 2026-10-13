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

    * `get_public_info/1` — full public info (name, model,
      status, modes, message_count, partial, usage).
    * `get_total_usage/1` — combined
      `usage_totals + descendant_usage` map.
    * `get_messages/1` — active message list.
    * `get_history/1` — archived history (compacted-away
      messages plus `{:compaction, _}` markers).
    * `terminate/1` — `GenServer.stop/2` with normal reason.
    * `get_status/2` — the agent's current status, read in
      the agent's own process.

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
  """
  @spec get_public_info(pid()) :: map()
  def get_public_info(pid) do
    GenServer.call(pid, :get_public_info)
  end

  @doc """
  Returns the combined usage map for the agent: `usage_totals +
  descendant_usage`, computed field-by-field.
  """
  @spec get_total_usage(pid()) :: map() | nil
  def get_total_usage(pid) do
    GenServer.call(pid, :get_total_usage)
  end

  @doc """
  Returns the active message history for the agent.
  """
  @spec get_messages(pid()) :: [Nest.Messages.Message.t()]
  def get_messages(pid) do
    GenServer.call(pid, :get_messages)
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
