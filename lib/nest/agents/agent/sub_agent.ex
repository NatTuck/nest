defmodule Nest.Agents.Agent.SubAgent do
  @moduledoc """
  Sub-agent delegation handlers for the `Agent` GenServer.

  Owns two concerns:

    * `handle_spawn_request/3` — a tool worker blocked on an
      `agents-spawn` tool call asked this agent to spawn a
      child. We delegate to the supervisor (fresh or
      context-cloned), record `{child_name => task_pid}` in
      `state.chat_state.pending_children` when a `query` is
      present, kick off `Agents.chat(child_name, query)`, then
      reply with the child's name (the worker matches its
      eventual `:spawn_agent_result` on it).

    * `handle_child_completed/4` — a child cast up the
      tree carrying its last assistant content and its
      total usage. We merge the child's total into the
      parent's `descendant_usage`, drop the pending entry,
      forward `:spawn_agent_result` to the worker (archiving
      the child first if it was spawned with `archive: true`),
      and broadcast an updated status (so the token chip's
      total updates mid-stream).

  ## Address strategy

  The child reaches the parent by `GenServer.cast`-ing to
  `Nest.Agents.Registry.via_tuple(space_id, parent_name)`. The
  parent looks the child up in `pending_children` by name (the
  `task_pid` is the only pid we hold; the worker has no
  registered name, so `:spawn_agent_result` reaches it via
  `send/2` from the parent).
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence

  @doc """
  Build a fresh-context child agent's attrs from a parent
  state and a chosen `vocation_id`. Unlike the clone path
  (which forks the parent's message history), the fresh child
  starts from a system-prompt-only context.

  `child_name` and `parent_id` are provided by the supervisor's
  `spawn_agent_in_space/3`. `exclude_spawn` is set when the
  child is spawned at max depth, so its tool list omits
  `agents-spawn` (non-clone spawns can be depth-limited safely).

  Returns the attrs map ready to pass to `start_link/1`.
  """
  @spec build_fresh_child_attrs(map(), String.t(), integer(), integer(), boolean()) :: map()
  def build_fresh_child_attrs(parent_state, child_name, parent_id, vocation_id, exclude_spawn) do
    %{
      name: child_name,
      space_id: parent_state.space_id,
      model: parent_state.model,
      vocation_id: vocation_id,
      workspace_path: parent_state.workspace_path,
      parent_id: parent_id,
      parent_name: parent_state.name,
      created_by_user_id: parent_state.created_by_user_id,
      shared: parent_state.shared,
      depth: parent_state.depth + 1,
      exclude_spawn: exclude_spawn,
      preloaded_messages: [],
      last_compaction_index: -1,
      next_message_index: 1,
      initial_api_log_sequences: %{}
    }
  end

  @doc """
  Spawn a child of `state` and remember the `task_pid` so the
  eventual completion can be forwarded. Unifies the old
  `clone_agent` (via `clone_context: true`) and the fresh
  `spawn_agent`. `opts` carries `name`, `vocation_id`,
  `clone_context`, `query`, and `archive`.

  Returns the GenServer reply tuple.
  """
  @spec handle_spawn_request(Agent.t(), pid(), map()) :: {:reply, term(), Agent.t()}
  def handle_spawn_request(state, task_pid, opts) do
    case spawn_child(state, opts) do
      {:ok, child_name} ->
        state = track_child(state, child_name, task_pid, opts)

        broadcast_subagent_creation(state, child_name)

        maybe_test_swap_to_mock(state.space_id, child_name)

        if Map.get(opts, :query, "") != "" do
          Nest.Agents.chat(state.space_id, child_name, Map.get(opts, :query))
        end

        {:reply, {:ok, child_name}, state}

      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  # Spawn the child via the appropriate path:
  #   * `clone_context: true` → fork the parent's message history
  #     (synthetic origin-story fork) at depth parent+1, tracked
  #     in ChildRegistry so the parent waits for completion.
  #   * otherwise → fresh-context specialist, `vocation_id`
  #     defaulting to the parent's.
  #
  # An agent at max depth cannot spawn children. For a clone
  # pre-compaction the `agents-spawn` tool is still present
  # (it must keep the parent's tool list), so the spawn is
  # rejected here at runtime rather than at tool-selection
  # time. Non-clone max-depth spawns already lack the tool.
  #
  # The spawn is whitelist- and workspace-checked by the
  # supervisor.
  defp spawn_child(state, opts) do
    if state.depth + 1 > Config.configured_max_depth() do
      {:error, :max_depth_reached}
    else
      do_spawn_child(state, opts)
    end
  end

  defp do_spawn_child(state, opts) do
    if Map.get(opts, :clone_context, false) do
      Supervisor.start_agent_with_parent(state, Map.get(opts, :query, ""))
    else
      vocation_id = Map.get(opts, :vocation_id) || state.vocation_id
      Supervisor.spawn_agent_in_space(state, Map.get(opts, :name, ""), vocation_id)
    end
  end

  # Register the child in `pending_children` only when it has a
  # `query` to answer (the worker is blocked awaiting the
  # result). A child spawned without a query runs independently
  # and never calls back, so there's nothing to track. When
  # `archive` is set, remember the child in
  # `chat_state.archiving` so `handle_child_completed/4`
  # archives it after the response is forwarded.
  defp track_child(state, child_name, task_pid, opts) do
    if Map.get(opts, :query, "") != "" do
      chat_state = %{
        state.chat_state
        | pending_children: Map.put(state.chat_state.pending_children, child_name, task_pid)
      }

      archiving =
        if Map.get(opts, :archive, false) do
          MapSet.put(state.chat_state.archiving, child_name)
        else
          state.chat_state.archiving
        end

      %{state | chat_state: %{chat_state | archiving: archiving}}
    else
      state
    end
  end

  @doc """
  Stop + mark an existing agent in `state`'s space archived.
  Used by the `agents-archive` tool. The target may be a peer
  or a child. Returns the GenServer reply tuple.
  """
  @spec handle_archive_request(Agent.t(), pid(), String.t()) :: {:reply, term(), Agent.t()}
  def handle_archive_request(state, _task_pid, name) do
    case Nest.Agents.Supervisor.archive_agent(state.space_id, name) do
      :ok ->
        {:reply, {:ok, name}, state}

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
  Merge `child_total_usage` into `state.llm_metrics.descendant_usage`,
  drop the pending entry, forward `:spawn_agent_result` to the
  blocked worker, archive the child if requested, and broadcast
  the updated status. Returns the GenServer reply tuple (which
  for a `handle_cast` is just `{:noreply, new_state}`).
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

        send(task_pid, {:spawn_agent_result, child_name, response})

        new_state = %{
          state
          | chat_state: %{
              state.chat_state
              | pending_children: new_pending,
                archiving: MapSet.delete(state.chat_state.archiving, child_name)
            },
            llm_metrics: new_llm_metrics
        }

        maybe_archive_completed_child(new_state, child_name)

        Broadcasts.status(new_state)
        {:noreply, new_state}
    end
  end

  # If the child was spawned with `archive: true`, stop + mark
  # it archived now that its response has been forwarded. Runs
  # after the status broadcast so the UI sees the final state.
  defp maybe_archive_completed_child(state, child_name) do
    if MapSet.member?(state.chat_state.archiving, child_name) do
      Nest.Agents.Supervisor.archive_agent(state.space_id, child_name)
    end

    :ok
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
  user-initiated Stop cuts off outstanding queries, and from
  `cascade_terminate/1` on GenServer death.

  Only children currently being queried (in `pending_children`)
  are stopped — idle specialists are left running. Archiving a
  whole subtree is handled separately by
  `Supervisor.archive_agent/2`.

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

    %{
      state
      | chat_state: %{state.chat_state | pending_children: %{}, archiving: %MapSet{}}
    }
  end

  @doc """
  Stop this agent's outstanding queries before the GenServer
  itself is torn down. Called from `Nest.Agents.Agent.terminate/2`.

  Only children currently being queried (in `pending_children`)
  are stopped — idle specialists survive their parent's death.
  Archiving a whole subtree is handled separately by
  `Supervisor.archive_agent/2`. We deliberately do NOT stop
  `state.name` itself — that's the supervisor's job, and we're
  already in our own `terminate/2` callback when this runs.
  """
  @spec cascade_terminate(Agent.t()) :: :ok
  def cascade_terminate(state) do
    _ = stop_pending_children(state)
    :ok
  catch
    # `rescue _ -> :ok` does NOT catch `:exit` — `catch :exit, _`
    # does. `stop_pending_children/1` reaches children via
    # `Supervisor.stop_agent/1` → `Process.exit/2`, which can
    # raise/exit under odd teardown ordering (e.g. the child
    # registry already torn down during application shutdown).
    # Without this catch, the Agent's `terminate/2` crashes and
    # logs an `[error]` during teardown — a noisy, recoverable
    # shutdown error.
    :exit, _ -> :ok
  end
end
