defmodule Nest.Agents.Agent.SubAgent do
  @moduledoc """
  Sub-agent delegation handlers for the `Agent` GenServer.

  Owns two concerns:

    * `handle_spawn_request/3` — a tool worker running an
      `agents-spawn` tool call asked this agent to spawn a
      child. We delegate to the supervisor (fresh or
      context-cloned), register the child in the machine's
      `Nest.Agents.Agent.Machine.Children` sub-machine when a
      `query` is present, kick off `Agents.chat(child_name,
      query)`, then reply with the child's name.

    * `handle_child_completed/4` — a child cast up the
      tree carrying its last assistant content and its
      total usage. We run the child event through the
      `Children` sub-machine, merge the reported usage into
      the parent's `descendant_usage`, enqueue the child's
      answer (or the news that it will not come) into the
      parent's *own* inbox (issue #31 §2.1 — archiving the child
      if it was spawned with `archive: true`), and broadcast an
      updated status (so the token chip's total updates
      mid-stream).

  ## Address strategy

  The child reaches the parent by `GenServer.cast`-ing to
  `Nest.Agents.Registry.via_tuple(space_id, parent_name)`. The
  parent looks the child up in the children sub-machine by name,
  and the outcome is delivered by the parent's own process into
  its own inbox: the caller's pid is not needed for the result,
  so a worker that has already gone cannot lose it.

  ## Usage accounting

  The child's usage is merged only through the `:completed`
  terminal transition. An `:abandoned` child (per-item deadline)
  that later completes does not merge usage — the user asked to
  stop everything. See `Machine.Children`.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Timeline
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence

  @doc """
  Build a fresh-context child agent's attrs from a parent
  state and a chosen vocation. Unlike the clone path
  (which forks the parent's message history), the fresh child
  starts from a system-prompt-only context.

  `child_name` and `parent_id` are provided by the supervisor's
  `spawn_agent_in_space/3`. `exclude_spawn` is set when the
  child is spawned at max depth, so its tool list omits
  `agents-spawn` (non-clone spawns can be depth-limited safely).
  `model_override` is an optional `%{name: ..., provider: ...}`
  map for the child's model; the child inherits the parent's
  model when it is `nil`.

  Returns the attrs map ready to pass to `start_link/1`.
  """
  @spec build_fresh_child_attrs(map(), String.t(), integer(), integer(), boolean(), map() | nil) ::
          map()
  def build_fresh_child_attrs(
        parent_state,
        child_name,
        parent_id,
        vocation_id,
        exclude_spawn,
        model_override \\ nil
      ) do
    %{
      name: child_name,
      space_id: parent_state.space_id,
      model: model_override || parent_state.model,
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
      next_message_index: 1
    }
  end

  @doc """
  Spawn a child of `state` and register it when it has a `query` to answer.
  Unifies the old `clone_agent` (via `clone_context: true`) and the fresh
  `spawn_agent`. `opts` carries `name`, `vocation` (slug), `clone_context`,
  `query`, and `archive`.

  The caller's pid is part of the call's shape but is no longer stored: the
  child's outcome goes to the parent's own inbox (§2.1), so nothing has to be
  sent back to the caller. Returns the GenServer reply tuple.
  """
  # A Stop is in flight. A batch coordinator's request can still be in this
  # mailbox (it was sent before the stop's kill reached that process), and
  # spawning for it now would start a child the parent has just stopped — and
  # register the dead coordinator as a reporting target, which is exactly what
  # makes the late `:DOWN` read as a lost batch.
  #
  # `:stopping` is the whole window, for every interleaving: the stop transition
  # kills every reporting target during its own settle, *before* the timer that
  # ends `:stopping` is armed, and a process with a pending `:kill` cannot run
  # again — so a request from a stopped batch is always enqueued ahead of that
  # timer's message and is therefore processed while the phase is `:stopping`
  # (mailbox order), not after the rest.
  @spec handle_spawn_request(Agent.t(), pid(), map()) :: {:reply, term(), Agent.t()}
  def handle_spawn_request(
        %Agent{live: %{machine: %{phase: :stopping}}} = state,
        _task_pid,
        _opts
      ) do
    {:reply, {:error, :stopping}, state}
  end

  def handle_spawn_request(state, _task_pid, opts) do
    case spawn_child(state, opts) do
      {:ok, child_name, model} ->
        state = track_child(state, child_name, opts)
        Timeline.child_spawned(state, child_name, model, opts)

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
  #   * otherwise → fresh-context specialist, `vocation` (slug)
  #     resolved by the supervisor against the space's blueprint
  #     whitelist (defaulting to the parent's, or the space's sole
  #     allowed vocation when the parent's isn't allowed).
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
    with {:ok, model_override} <- resolve_model_override(Map.get(opts, :model, "")) do
      result =
        if Map.get(opts, :clone_context, false) do
          Supervisor.start_agent_with_parent(state, Map.get(opts, :query, ""), model_override)
        else
          # The supervisor resolves `vocation` (a slug) against the
          # space's blueprint whitelist: omitted defaults to the
          # parent's vocation (or the space's sole allowed vocation when
          # the parent's isn't allowed).
          Supervisor.spawn_agent_in_space(
            state,
            Map.get(opts, :name, ""),
            Map.get(opts, :vocation),
            model_override
          )
        end

      # The resolved model rides back with the name so the spawn's timeline
      # event reports what the child actually runs on, not what was asked for.
      with {:ok, child_name} <- result, do: {:ok, child_name, model_override || state.model}
    end
  end

  # Parse the optional `agents-spawn` `model` argument (a
  # `"provider/name"` string, as returned by `models-list`) into
  # the child's model map. Splitting on the FIRST slash keeps
  # model names that themselves contain slashes (e.g.
  # `"vllm/Qwen/Qwen3.5-122B-A10B-FP8"`) intact. Absent or empty
  # means inherit the parent's model (`{:ok, nil}`); anything
  # unparseable is rejected so the spawn fails loudly instead of
  # silently starting the child on the wrong model.
  defp resolve_model_override(nil), do: {:ok, nil}
  defp resolve_model_override(""), do: {:ok, nil}

  defp resolve_model_override(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, name] when provider != "" and name != "" ->
        {:ok, %{name: name, provider: provider}}

      _ ->
        {:error, {:invalid_model, model}}
    end
  end

  # Register the child in the machine's children sub-machine only when
  # it has a `query` to answer, so its answer is worth delivering. A child
  # spawned without a query runs independently and never calls back, so
  # there's nothing to track. The `archive` flag is carried on the child entry
  # so the terminal transition can emit a single archive action alongside the
  # answer, and `report_to` — set only by the batch coordinator — names the pid
  # the outcome goes to instead of this agent's own inbox.
  defp track_child(state, child_name, opts) do
    if Map.get(opts, :query, "") != "" do
      archive = Map.get(opts, :archive, false)
      target = Map.get(opts, :report_to)

      # A reporting target (a batch coordinator) is monitored so that a
      # coordinator which dies before its aggregate is *reported*, not silently
      # missed. Once per target — a batch's other children report to the same
      # pid, and a second monitor would deliver a second `:DOWN`. The ref is
      # deliberately dropped: the `:DOWN` is matched by pid in `Turn.handle/2`.
      if is_pid(target) and not Children.reporting_target?(state.live.machine.children, target) do
        Process.monitor(target)
      end

      {:ok, state} = Turn.settle(state, {:child_spawned, child_name, archive, target})

      state
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

  # A tool worker (running an `agents-batch`) hit a per-item deadline and
  # asked us to abandon one of its children. The `Children` sub-machine's
  # `:abandoned` transition is terminal (so a late `:child_completed`
  # becomes a defensive no-op) and emits a single `{:stop_child, name}`
  # action, which the executor runs. We do NOT archive here — the child
  # never produced a response, so there is nothing to keep. Replies `:ok`
  # so the worker's blocking `GenServer.call/3` unblocks.
  @spec handle_abandon_child(Agent.t(), pid(), String.t()) :: {:reply, :ok, Agent.t()}
  def handle_abandon_child(state, _task_pid, name) do
    {:reply, :ok, apply_child_event(state, {:abandoned, name})}
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
  Merge the child's reported usage into
  `state.llm_metrics.descendant_usage`, enqueue the child's answer into the
  parent's own inbox, archive the child if it was spawned with
  `archive: true`, and broadcast the updated status. Returns the GenServer
  reply tuple (which for a `handle_cast` is just `{:noreply, new_state}`).
  """
  @spec handle_child_completed(Agent.t(), String.t(), String.t(), map()) ::
          {:noreply, Agent.t()}
  def handle_child_completed(state, child_name, response, child_total_usage) do
    {:noreply, apply_child_event(state, {:completed, child_name, response, child_total_usage})}
  end

  @doc """
  A child ended its turn without a normal completion (its
  chat crashed or was stopped). Run the failure through the
  `Children` sub-machine, which enqueues a runtime notice into the parent's
  own inbox so the caller learns the answer is not coming instead of waiting
  it out. Never archives a failed child — a crashed/stopped child is left in
  place for inspection. Returns the GenServer reply tuple.
  """
  @spec handle_child_failed(Agent.t(), String.t(), term()) :: {:noreply, Agent.t()}
  def handle_child_failed(state, child_name, reason) do
    {:noreply, apply_child_event(state, {:failed, child_name, reason})}
  end

  @doc """
  A registered child process died before completing (crash, Stop,
  external archive, cascade teardown). Same fail-fast handling as
  `handle_child_failed/3`. Never archives. Returns the GenServer
  reply tuple.
  """
  @spec handle_child_terminated(Agent.t(), String.t(), term()) :: {:noreply, Agent.t()}
  def handle_child_terminated(state, child_name, reason) do
    {:noreply, apply_child_event(state, {:terminated, child_name, reason})}
  end

  # Apply one child lifecycle event to the machine, then run the actions the
  # pure `Children` sub-machine returned (the inbox enqueue, the usage merge,
  # the archive).
  defp apply_child_event(state, event) do
    event =
      case event do
        {:completed, name, response, usage} -> {:child_completed, name, response, usage}
        {:failed, name, reason} -> {:child_failed, name, reason}
        {:terminated, name, reason} -> {:child_terminated, name, reason}
        {:abandoned, name} -> {:abandon_child, name}
      end

    {:ok, state} = Turn.settle(state, event)
    state
  end

  # Notify all connected lobby clients that a subagent has
  # been spawned so the sidebar tree updates live without a
  # page refresh. Uses the Phoenix Endpoint broadcast channel
  # so the message arrives through the standard channel
  # pipeline (no raw PubSub bypass needed by the lobby). The
  # `space_id` is required — the frontend groups agents by it
  # when adding one to the sidebar.
  defp broadcast_subagent_creation(state, child_name) do
    parent_db_id =
      case Persistence.fetch_agent(state.space_id, state.name) do
        {:ok, row} -> row.id
        _ -> nil
      end

    NestWeb.Endpoint.broadcast("lobby", "agent:created", %{
      "name" => child_name,
      "space_id" => state.space_id,
      "model" => state.model,
      "status" => "idle",
      "parentId" => parent_db_id,
      "parentName" => state.name,
      "depth" => state.depth + 1
    })
  end

  @doc """
  Stop every currently-running child and clear the children
  sub-machine. Called from the Agent's `{:chat_stopped, _}` handler
  (`Turn.handle/2`) so a user-initiated Stop cuts off outstanding queries,
  and from `cascade_terminate/1` on GenServer death.

  Only children currently being queried (running) are stopped — idle
  specialists are left running. Archiving a whole subtree is handled
  separately by `Supervisor.archive_agent/2`.

  `Supervisor.stop_agent/1` returns `:ok` on success and
  `{:error, :not_found}` when the child has already terminated (e.g. it
  finished during the same `chat_stopped` flush). Both outcomes satisfy
  "no descendants are running," so we discard them all. `ChildRegistry`'s
  `:DOWN` self-cleanup keeps the bookkeeping consistent if a child died
  between iteration steps.

  The returned state has the children sub-machine reset to empty so a
  late-arriving `:child_completed` cast (a child that finished
  milliseconds before we stopped it) becomes a defensive no-op.
  """
  @spec stop_pending_children(Agent.t()) :: Agent.t()
  def stop_pending_children(state) do
    machine = state.live.machine

    machine
    |> Machine.running_child_names()
    |> Enum.each(fn child_name ->
      _ = Supervisor.stop_agent(state.space_id, child_name)
    end)

    put_machine(state, Machine.clear_children(machine))
  end

  @doc """
  Stop this agent's outstanding queries before the GenServer
  itself is torn down. Called from `Nest.Agents.Agent.terminate/2`.

  Only children currently being queried (running) are stopped — idle
  specialists survive their parent's death. Archiving a whole subtree is
  handled separately by `Supervisor.archive_agent/2`. We deliberately do
  NOT stop `state.name` itself — that's the supervisor's job, and we're
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

  defp put_machine(state, machine), do: %{state | live: %{state.live | machine: machine}}
end
