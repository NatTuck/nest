defmodule Nest.Agents.Agent.SubAgent do
  @moduledoc """
  Sub-agent delegation handlers for the `Agent` GenServer.

  Owns two concerns:

    * `handle_clone_request/3` — a tool worker blocked on a
      `clone_agent` tool call asked this agent to spawn a
      child. We pull the parent's integer `agents.id`,
      delegate to `Supervisor.start_agent_with_parent/2`,
      record `{child_name => task_pid}` in
      `state.chat_state.pending_children`, kick off
      `Agents.chat(child_name, instruction)`, then reply
      with the child's name (the worker matches its
      eventual `:clone_agent_result` on it).

    * `handle_child_completed/4` — a child cast up the
      tree carrying its last assistant content and its
      total usage. We merge the child's total into the
      parent's `descendant_usage`, drop the pending entry,
      forward `:clone_agent_result` to the worker, and
      broadcast an updated status (so the token chip's
      total updates mid-stream).

  ## Address strategy

  The child reaches the parent by `GenServer.cast`-ing to
  `Nest.Agents.Registry.via_tuple(space_id, parent_name)`. The
  parent looks the child up in `pending_children` by name (the
  `task_pid` is the only pid we hold; the worker has no
  registered name, so `:clone_agent_result` reaches it via
  `send/2` from the parent).
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence

  @doc """
  Spawn a child of `state` for the supplied `instruction`
  and remember the `task_pid` so the eventual completion
  can be forwarded. Returns the GenServer reply tuple.
  """
  @spec handle_clone_request(Agent.t(), pid(), String.t()) :: {:reply, term(), Agent.t()}
  def handle_clone_request(state, task_pid, instruction) do
    case Supervisor.start_agent_with_parent(state, instruction) do
      {:ok, child_name} ->
        chat_state = %{
          state.chat_state
          | pending_children: Map.put(state.chat_state.pending_children, child_name, task_pid)
        }

        state = %{state | chat_state: chat_state}

        broadcast_subagent_creation(state, child_name)

        maybe_test_swap_to_mock(state.space_id, child_name)

        Nest.Agents.chat(state.space_id, child_name, instruction)

        {:reply, {:ok, child_name}, state}

      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  # Test-only: if the `:nest` app env has
  # `:force_subagent_mock` set (by an async test that
  # wants the spawned child's first LLM call to use
  # `Nest.LLM.MockClient` instead of a real HTTP
  # client), swap the freshly-spawned child's
  # `:client_config.client` and start a per-child
  # MockClient queue.
  #
  # Production never sets the env, so this is a single
  # `Application.get_env/3` per spawn (cheap).
  #
  # We use the app env rather than a `Process.get` so the
  # check works regardless of which BEAM process the
  # parent GenServer happens to run in (the test process,
  # the dynamic supervisor, etc.).
  @doc false
  def maybe_test_swap_to_mock(space_id, child_name) do
    if Application.get_env(:nest, :force_subagent_mock, false) do
      swap_to_mock(space_id, child_name)
    end

    :ok
  end

  # Test-only: swap the freshly-spawned child's
  # `:client_config.client` to `MockClient` so the child's
  # first LLM call doesn't make a real HTTP request. We
  # also start a per-child MockClient queue so the chat
  # task finds a queue keyed by the child's pid.
  defp swap_to_mock(space_id, child_name) do
    case AgentsRegistry.lookup(space_id, child_name) do
      {:ok, pid} ->
        :sys.replace_state(pid, fn st ->
          %{st | client_config: %{st.client_config | client: MockClient}}
        end)

        MockClient.start_link(pid)

      _ ->
        :ok
    end
  end

  @doc """
  Spawn an independent, fresh-context sub-agent in `state`'s
  space via `Supervisor.spawn_agent_in_space/3`.

  Unlike `handle_clone_request/3`, this does NOT register a
  `pending_children` entry or wait for completion — the spawned
  specialist runs independently and the worker returns
  immediately with its name. Used by the `spawn_agent` tool.

  The `task_pid` is unused here (the reply is returned
  synchronously to the worker, which is the same process on a
  `GenServer.call`), but kept for signature symmetry with
  `handle_clone_request/3`.
  """
  @spec handle_spawn_request(Agent.t(), pid(), String.t(), integer()) ::
          {:reply, term(), Agent.t()}
  def handle_spawn_request(state, _task_pid, name, vocation_id) do
    case Supervisor.spawn_agent_in_space(state, name, vocation_id) do
      {:ok, spawned_name} ->
        maybe_test_swap_to_mock(state.space_id, spawned_name)
        {:reply, {:ok, spawned_name}, state}

      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  @doc """
  Merge `child_total_usage` into `state.llm_metrics.descendant_usage`,
  drop the pending entry, forward `:clone_agent_result` to the
  blocked worker, and broadcast the updated status. Returns
  the GenServer reply tuple (which for a `handle_cast` is just
  `{:noreply, new_state}`).
  """
  @spec handle_child_completed(Agent.t(), String.t(), String.t(), map()) ::
          {:noreply, Agent.t()}
  def handle_child_completed(state, child_name, response, child_total_usage) do
    case Map.get(state.chat_state.pending_children, child_name) do
      nil ->
        # Defensive: shouldn't happen in production
        # (every child that casts up the tree is in the
        # map). Drop silently if it does.
        {:noreply, state}

      task_pid ->
        new_pending = Map.delete(state.chat_state.pending_children, child_name)

        new_llm_metrics = %{
          state.llm_metrics
          | descendant_usage:
              Broadcasts.total_usage(state.llm_metrics.descendant_usage, child_total_usage)
        }

        send(task_pid, {:clone_agent_result, child_name, response})

        new_state = %{
          state
          | chat_state: %{state.chat_state | pending_children: new_pending},
            llm_metrics: new_llm_metrics
        }

        Broadcasts.status(new_state)
        {:noreply, new_state}
    end
  end

  # Notify all connected lobby clients that a subagent has
  # been spawned so the sidebar tree updates live without a
  # page refresh. Uses the Phoenix Endpoint broadcast channel
  # so the message arrives through the standard channel
  # pipeline (no raw PubSub bypass needed by the lobby).
  defp broadcast_subagent_creation(state, child_name) do
    parent_db_id =
      case Persistence.fetch_agent(state.space_id, state.name) do
        {:ok, row} -> row.id
        _ -> nil
      end

    NestWeb.Endpoint.broadcast("lobby", "agent:created", %{
      "name" => child_name,
      "model" => state.model,
      "status" => "idle",
      "parentId" => parent_db_id,
      "parentName" => state.name,
      "depth" => state.depth + 1
    })
  end

  @doc """
  Stop every agent in `state.chat_state.pending_children` and clear
  the map. Called from `ChatTurnHandler.chat_stopped/1` so a
  user-initiated Stop cascades through the same `Supervisor` walk
  that `terminate/2` already does on GenServer death.

  The walk is recursive for free: `Supervisor.stop_agent/1` walks
  each child's registered grandchildren before terminating the
  child itself, and each child's `terminate/2` re-enters
  `cascade_terminate/1` → `Supervisor.cascade_children_only/1`,
  so the cascade holds at any depth up to `max_depth`.

  `Supervisor.stop_agent/1` returns `:ok` on success and
  `{:error, :not_found}` when the child has already terminated
  (e.g. it finished during the same `chat_stopped` flush). Both
  outcomes satisfy "no descendants are running," so we discard
  them all. `ChatRegistry`'s `:DOWN` self-cleanup keeps the
  bookkeeping consistent if a child died between iteration steps.

  The returned state has `pending_children` cleared to `%{}` so a
  late-arriving `:child_completed` cast (a child that finished
  milliseconds before we stopped it) becomes a defensive no-op in
  `handle_child_completed/4` via its `Map.get`-then-`nil`
  short-circuit.
  """
  @spec stop_pending_children(Agent.t()) :: Agent.t()
  def stop_pending_children(state) do
    state.chat_state.pending_children
    |> Enum.each(fn {child_name, _task_pid} ->
      _ = Supervisor.stop_agent(state.space_id, child_name)
    end)

    %{state | chat_state: %{state.chat_state | pending_children: %{}}}
  end

  @doc """
  Cascade-stop this agent's registered children before the
  GenServer itself is torn down. Called from
  `Nest.Agents.Agent.terminate/2`.

  The implementation reaches each child by name through the
  supervisor's cascade path. It deliberately does NOT try
  to terminate `state.name` itself — that's the supervisor's
  job, and we're already in our own `terminate/2` callback
  when this runs. Each child's own `terminate/2` cascades
  its own subtree, so the call is recursive at the
  runtime level.
  """
  @spec cascade_terminate(Agent.t()) :: :ok
  def cascade_terminate(state) do
    Nest.Agents.Supervisor.cascade_children_only(state.space_id, state.name)
    :ok
  catch
    # `rescue _ -> :ok` does NOT catch `:exit` — `catch :exit, _`
    # does. The supervisor's `cascade_children_only/1` makes a
    # `GenServer.call` to `Nest.Agents.ChildRegistry`, which exits
    # `:noproc` during application shutdown (ChildRegistry is
    # torn down after the agent's supervisor in reverse start
    # order). Without this catch, the Agent's `terminate/2`
    # crashes with `(stop) exited in: GenServer.call(...)` and
    # logs an `[error]` per agent during teardown — a noisy,
    # recoverable shutdown error.
    :exit, _ -> :ok
  end
end
