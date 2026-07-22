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
  `Nest.Agents.Registry.via_tuple(parent.name)`. The parent
  looks the child up in `pending_children` by name (the
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

        maybe_test_swap_to_mock(child_name)

        agents_chat(child_name, instruction)

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
  def maybe_test_swap_to_mock(child_name) do
    if Application.get_env(:nest, :force_subagent_mock, false) do
      swap_to_mock(child_name)
    end

    :ok
  end

  # Test-only: swap the freshly-spawned child's
  # `:client_config.client` to `MockClient` so the child's
  # first LLM call doesn't make a real HTTP request. We
  # also start a per-child MockClient queue so the chat
  # task finds a queue keyed by the child's pid.
  defp swap_to_mock(child_name) do
    case AgentsRegistry.lookup(child_name) do
      {:ok, pid} ->
        :sys.replace_state(pid, fn st ->
          %{st | client_config: %{st.client_config | client: MockClient}}
        end)

        MockClient.start_link(pid)

      _ ->
        :ok
    end
  end

  # Helper — `Nest.Agents.chat/3` keeps its public API at
  # `Nest.Agents.chat/3`; we route the call through the named
  # registry so this module never holds a child pid.
  defp agents_chat(name, content),
    do: Nest.Agents.chat(name, content)

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

        Broadcasts.status(state.name, new_state)
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
      case Persistence.fetch_agent_by_name(state.name) do
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
    Nest.Agents.Supervisor.cascade_children_only(state.name)
    :ok
  rescue
    _ -> :ok
  end
end
