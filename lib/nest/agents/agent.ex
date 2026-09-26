defmodule Nest.Agents.Agent.TreePosition do
  @moduledoc """
  Sub-struct holding the agent's position in the spawned
  child tree. Extracted from the parent `Agent` struct so
  the parent doesn't push past the 16-field cap.

  `parent_id` is the integer `agents.id` of the agent that
  spawned this one via `agents-spawn` (with `clone_context`). `nil` for root agents.
  `parent_name` is the parent's readable identifier (a
  String), held so the child can dispatch messages to the
  parent's GenServer through `Agents.Registry.via_tuple/2`
  without an integer→name lookup at completion time.

  `fork_message_index` is the clone's first own `message_index`.
  The clone shares its ancestors' rows below it and owns from it
  up (see `notes/shared-message-structure.md`). `nil` for a root
  or a fresh child (owns from index 0) and for a clone that has
  detached at compaction (owns its own rows, no shared prefix).
  """

  defstruct parent_id: nil, parent_name: nil, fork_message_index: nil
end

defmodule Nest.Agents.Agent do
  @moduledoc """
  GenServer that manages an individual agent's state and chat.

  Each agent runs as an independent process with a unique
  readable name, message history with tool calling, LLM client
  config, and streaming broadcast support via PubSub.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Nest.Agents.Agent.Callbacks
  alias Nest.Agents.Agent.ClientAPI
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.Registry
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  defstruct [
    :name,
    :space_id,
    :model,
    :client_config,
    :vocation_id,
    :vocation,
    :workspace_path,
    :tmp_path,
    :tools,
    :llm_metrics,
    :created_by_user_id,
    # `depth` is the agent's distance from its tree root (0 =
    # root). Children inherit `parent.depth + 1`; `agents-spawn`
    # is disabled at `depth >= configured_max_depth()`. Persisted
    # via `agents.depth`.
    depth: 0,
    # `shared` mirrors `agents.shared` so the lobby filter
    # and ownership checks don't need a DB lookup. Children
    # inherit their parent's `shared` value (see
    # `build_child_attrs/4`).
    shared: false,
    # `tree_position` is `%__MODULE__.TreePosition{}` for
    # child agents (carrying `parent_id` + `parent_name`) and
    # the default (both fields `nil`) for root agents. Extracted
    # into a sub-struct so the top-level `Agent` stays under
    # the 16-field cap (credo's `Modules#MODULE_DOC`).
    tree_position: %__MODULE__.TreePosition{},
    chat_state: %__MODULE__.ChatState{},
    live: %__MODULE__.ChatState.Live{}
  ]

  # Read-only context threaded through a single chat turn is
  # constructed by `ChatPipeline.spawn_chat_turn/1` and lives on
  # the ChatTurn's `ctx` field. The Agent is the storage layer
  # + lifecycle router; the ChatTurn drives the iteration.
  #
  # The agent's system prompt lives at position 0 of
  # `state.chat_state.messages` (a `{:system, %System{}}` tuple).
  # There is no separate `system_prompt` field — the messages
  # array is the single source of truth for the immutable initial
  # system content as well as any late runtime reminders.

  @type t :: %__MODULE__{
          name: String.t(),
          space_id: integer(),
          model: map(),
          client_config: ClientConfig.t(),
          vocation: Vocations.Vocation.t(),
          workspace_path: String.t() | nil,
          tmp_path: String.t() | nil,
          tools: [Nest.LLM.Tool.t()],
          llm_metrics: __MODULE__.LlmMetrics.t(),
          tree_position: __MODULE__.TreePosition.t(),
          created_by_user_id: integer() | nil,
          shared: boolean(),
          depth: non_neg_integer(),
          chat_state: __MODULE__.ChatState.t(),
          live: __MODULE__.ChatState.Live.t()
        }

  @type message ::
          {:system, System.t()}
          | {:user, User.t()}
          | {:assistant, Assistant.t()}
          | {:tool, Tool.t()}

  # Client API

  @doc """
  Starts an agent process with the given attributes.

  Required keys:
  - `:name` - Unique readable agent name (the human identifier)
  - `:model` - Model configuration map with :name key

  Pure spawn. Pre-spawn DB work (agent row + system message
  inserts) is the caller's responsibility — call `Agent.pre_spawn/1`
  in the caller's pid before `start_link/1`. The supervisor pid
  (or any pid that wraps `start_link/1` via `DynamicSupervisor`)
  has no DB work to do, so it doesn't need a Sandbox checkout.

  The agent registers itself in the Registry under its name.
  """
  @spec start_link(attrs :: map()) :: GenServer.on_start()
  def start_link(attrs) do
    name = Map.fetch!(attrs, :name)
    space_id = Map.fetch!(attrs, :space_id)
    GenServer.start_link(__MODULE__, attrs, name: Registry.via_tuple(space_id, name))
  end

  @doc """
  Pre-spawn DB work for `start_link/1`. Inserts the agent row
  and the initial system message in the *caller's* DB context
  (test pid for tests, channel pid for production) so the
  supervisor pid never has to do DB work during spawn.

  Returns `:ok` on success, `{:error, reason}` on failure. On
  `:duplicate_name` the row is left untouched — the caller
  decides whether to retry with a fresh name or surface the
  error.
  """
  @spec pre_spawn(map()) :: :ok | {:error, term()}
  def pre_spawn(attrs) do
    case Map.get(attrs, :fork_message_index) do
      nil -> pre_spawn_with_system(attrs)
      fork_index -> pre_spawn_clone(attrs, fork_index)
    end
  end

  # Root and fresh-child path: own the system row at index 0.
  defp pre_spawn_with_system(attrs) do
    # Refuse an agent without a non-empty system message (validate first).
    case build_initial_system_message(attrs) do
      {:ok, system_message} ->
        with {:ok, _} <- Persistence.insert_agent(attrs),
             {:ok, _} <- Persistence.insert_message(attrs.space_id, attrs.name, system_message) do
          :ok
        end

      {:error, :missing_system_prompt} ->
        {:error, :missing_system_prompt}
    end
  end

  # Clone path: persist only the rows the clone owns (indices at or
  # above its fork boundary). The shared prefix is inherited from the
  # ancestors and never duplicated (D1/D2), and index 0 belongs to the
  # root ancestor, so no system row is written (D5).
  defp pre_spawn_clone(attrs, fork_index) do
    own_messages =
      attrs
      |> Map.get(:preloaded_messages, [])
      |> Enum.filter(fn {_role, %{index: idx}} -> idx >= fork_index end)

    with {:ok, _} <- Persistence.insert_agent(attrs) do
      persist_own_messages(attrs, own_messages)
    end
  end

  defp persist_own_messages(attrs, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case Persistence.insert_message(attrs.space_id, attrs.name, message) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Render the system prompt in the calling process (so the DB write
  # runs in a pid with DB access); `nil` only when the vocation is missing.
  defp build_initial_system_message(attrs) do
    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)
    workspace_path = Map.get(attrs, :workspace_path)
    vocation = Map.get(attrs, :vocation)
    depth = Map.get(attrs, :depth, 0)

    {context_limit, context_limit_source} = Init.initial_context_limit(model)

    {system_prompt, _mode, _tools, _cached_vocation} =
      SystemPrompt.compose_vocation_config(
        vocation,
        workspace_path,
        {context_limit, context_limit_source},
        name,
        depth
      )

    case system_prompt do
      text when is_binary(text) and text != "" ->
        {:ok,
         {:system,
          %System{
            index: 0,
            parts: [%Part.Text{text: text}],
            timestamp: DateTime.utc_now(),
            api_logs: []
          }}}

      _ ->
        {:error, :missing_system_prompt}
    end
  end

  @doc """
  Build a child agent's attrs from a parent state and the
  clone instruction. Pure data shaping — no DB writes, no
  spawning.

  The caller (the supervisor's `start_agent_with_parent/2`)
  provides:
    * `child_name` — a freshly-generated unique name
    * `parent_id` — the parent's integer `agents.id`,
      resolved via `Persistence.fetch_agent/2`
    * `model_override` — an optional `%{name: ..., provider: ...}`
      map for the child's model; the child inherits the parent's
      model when it is `nil`

  Returns the attrs map ready to pass to `start_link/1`.
  """
  @spec build_child_attrs(map(), String.t(), String.t(), integer(), map() | nil) :: map()
  def build_child_attrs(parent_state, instruction, child_name, parent_id, model_override \\ nil)
      when is_map(parent_state) and is_binary(instruction) and is_binary(child_name) do
    # The clone shares the parent's *full* sequence (history +
    # active) up to the fork point. `next_message_index` is the
    # first index the child owns, i.e. its fork boundary `F`; the
    # shared prefix is everything with a lower index. See
    # `notes/shared-message-structure.md`.
    shared_prefix = parent_state.chat_state.history ++ parent_state.chat_state.messages
    fork_index = parent_state.chat_state.next_message_index

    {preloaded, next_index} =
      MessageList.build_clone_fork(shared_prefix, fork_index, child_name, parent_state.depth + 1)

    %{
      name: child_name,
      space_id: parent_state.space_id,
      model: model_override || parent_state.model,
      vocation_id: parent_state.vocation_id,
      vocation: parent_state.vocation,
      workspace_path: parent_state.workspace_path,
      parent_id: parent_id,
      parent_name: parent_state.name,
      # Children inherit the parent's user identity and
      # visibility — a private agent always spawns private
      # children, and a shared parent may spawn shared
      # children. The child can be flipped later via an
      # edit flow (currently the new-agent form is the only
      # place to set `shared`).
      created_by_user_id: parent_state.created_by_user_id,
      shared: parent_state.shared,
      depth: parent_state.depth + 1,
      # `nil` for a fresh child (owns from 0); the first owned
      # index for a clone (shares everything below it).
      fork_message_index: fork_index,
      preloaded_messages: preloaded,
      last_compaction_index: Map.get(parent_state.chat_state, :last_compaction_index, -1),
      next_message_index: next_index
    }
  end

  @doc """
  Sends a chat message to the agent.

  The message is added to the chain and triggers a streaming response
  from the LLM. Responses are broadcast via PubSub to all subscribers.

  The optional `mode` selects the sandbox capability profile for this
  message's tool calls. When `nil`, the agent falls back to its
  default mode (first key in the vocation's `modes` map, or `"chat"`
  if no modes are defined).
  """
  @spec chat(pid(), String.t(), String.t() | nil) :: :ok
  def chat(pid, content, mode \\ nil) do
    GenServer.cast(pid, {:chat, content, mode})
  end

  @doc """
  Signal the in-flight chat task (if any) to stop. `from` is the
  channel pid that initiated the stop (used so the ChatTurn
  can ack `:stopped` to it). Blocks until the Agent's
  `handle_call({:stop_chat, _})` returns. A no-op when idle;
  idempotent.
  """
  @spec stop_chat(pid(), pid()) :: :ok
  def stop_chat(pid, from \\ self()) do
    GenServer.call(pid, {:stop_chat, from}, :infinity)
  end

  @doc """
  Re-run the compactor after a `:compaction_failed` status.
  Handler no-ops when the agent isn't in `:compaction_failed`.

  Synchronous: the channel's `handle_in("chat:retry-compaction", ...)`
  reply now lands after the agent has actually handled the
  retry, not the moment the message queued. `GenServer.call/3`
  with `:infinity` timeout matches `set_model/2`'s call
  contract; the retry handler is fast (log + state return) so
  the unbounded wait is fine.
  """
  @spec retry_compaction(pid()) :: :ok
  def retry_compaction(pid), do: GenServer.call(pid, :retry_compaction, :infinity)

  @doc """
  Acknowledge a `:compaction_loop_detected` status. Handler
  no-ops when the agent isn't in that status.

  Synchronous: the channel's reply is held until the agent
  has cleared the loop state (or logged the no-op warning).
  """
  @spec compaction_loop_detected_ok(pid()) :: :ok
  def compaction_loop_detected_ok(pid),
    do: GenServer.call(pid, :compaction_loop_detected_ok, :infinity)

  # Change the agent's resolved LLM client + persisted `model` map.
  # Handler: `IntrospectionHandler` → `ModelHandler`.
  @spec set_model(pid(), map()) :: :ok | {:error, term()}
  def set_model(pid, new_model), do: GenServer.call(pid, {:set_model, new_model}, :infinity)

  # Change the agent's working directory. Handler: `WorkspaceHandler`.
  @spec set_workspace(pid(), String.t() | nil) :: :ok | {:error, term()}
  def set_workspace(pid, workspace_path),
    do: GenServer.call(pid, {:set_workspace, workspace_path}, :infinity)

  # Combined edit: model (and thinking level) + working directory in one
  # call. Handler: `ModelHandler`.
  @spec edit_agent(pid(), map(), String.t() | nil) :: :ok | {:error, term()}
  def edit_agent(pid, model, workspace_path),
    do: GenServer.call(pid, {:edit_agent, model, workspace_path}, :infinity)

  @doc """
  Resolve the agent's current effective sandbox caps from its state.

  Uses the same `Vocations.get_caps/2` lookup as the chat pipeline so
  bookkeeping file access (AGENTS.md reads, policy stats) is
  authorized by the same caps the tools run under. Falls back to the
  `Nest.Sandbox` default profile when there is no vocation or the
  mode is unknown.
  """
  @spec resolve_caps(t()) :: map()
  def resolve_caps(%__MODULE__{vocation: %Nest.Vocations.Vocation{} = vocation} = state) do
    case Nest.Vocations.get_caps(vocation, state.live.mode) do
      {:ok, caps} -> caps
      _ -> Nest.Sandbox.default_caps()
    end
  end

  def resolve_caps(_), do: Nest.Sandbox.default_caps()

  @doc """
  Test-only: returns the pid of the in-flight ChatTurn (or
  `nil` if the agent is idle). Production code should use
  `stop_chat/2` instead. Re-export of `ClientAPI.get_chat_turn_pid/1`.
  """
  defdelegate get_chat_turn_pid(pid), to: ClientAPI

  @doc """
  Terminates the agent process. Re-export of `ClientAPI.terminate/1`.
  """
  defdelegate terminate(pid), to: ClientAPI

  # Returns public agent info for the WebSocket protocol (id, model,
  # message_count, status, vocation_id, partial, parent, usage, ...).
  # Re-export of `ClientAPI.get_public_info/1`.
  defdelegate get_public_info(pid), to: ClientAPI

  # Returns the combined usage map for the agent: `usage_totals +
  # descendant_usage`, computed field-by-field. Re-export of
  # `ClientAPI.get_total_usage/1`.
  defdelegate get_total_usage(pid), to: ClientAPI

  @doc """
  Returns the active message list for the agent.

  Re-export of `ClientAPI.get_messages/1`.
  """
  defdelegate get_messages(pid), to: ClientAPI

  @doc """
  Returns the archived history for the agent.

  Re-export of `ClientAPI.get_history/1`.
  """
  defdelegate get_history(pid), to: ClientAPI

  @doc """
  Fetch API logs for a specific message by index. Delegates to the
  GenServer's introspection handler.
  """
  defdelegate get_api_logs(pid, index), to: ClientAPI

  # Server Callbacks

  @impl true
  def init(attrs) do
    # Trap exits to ensure cleanup runs when agent is stopped
    Process.flag(:trap_exit, true)

    if persistence_enabled?() do
      do_init(attrs)
    else
      {:stop, :non_persistence_not_implemented}
    end
  end

  defp do_init(attrs) do
    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)

    case Config.create_client_config(model) do
      {:ok, client_config} ->
        state = build_active_state(attrs, client_config)

        case Map.get(attrs, :sequence_violations, []) do
          [] ->
            log_active_start(state)
            {:ok, state}

          violations ->
            {:ok, Init.NeedsRepair.block(state, violations, Map.get(attrs, :repair_command))}
        end

      {:error, reason} ->
        # The persisted model no longer resolves to a runtime
        # provider (e.g. the provider was removed from
        # `~/.config/nest/config.toml`). Earlier behavior was
        # `:stop, reason`, which silently filtered the agent out
        # of `list_agents_info/0` and made it impossible to load
        # or repair from the UI. Instead, start the agent with
        # an inert `RecoveryClient` and a `:model_missing` status.
        # The channel layer blocks inbound `chat:message`
        # traffic while in this state and the lobby surfaces the
        # row via `list_broken_agents/0`, so the user can call
        # `Agents.change_model/2` to transition back to `:idle`.
        Logger.error(
          "Agent #{name} could not resolve model #{inspect(model)}: #{inspect(reason)}. " <>
            "Starting in :model_missing state — pick a replacement model to recover."
        )

        {:ok, Callbacks.build_recovery_state(attrs, model, reason)}
    end
  end

  # Happy-path state construction: build from attrs, hydrate
  # the persisted message sequence, then log a structured
  # start banner. Extracted from `init/1` so the top-level
  # case statement stays readable.
  #
  # Pure: no DB writes here. `start_link/1` pre-persists the
  # agent row and the system message in the calling process
  # so the child pid's `init/1` doesn't need `$callers`
  # propagation back to a Sandbox owner.
  defp build_active_state(attrs, client_config) do
    state = Init.build_state(attrs, client_config)

    Init.seed_from_db(
      state,
      Map.get(attrs, :preloaded_messages, []),
      Map.get(attrs, :last_compaction_index, -1)
    )
  end

  defp log_active_start(state) do
    Logger.info(
      "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.live.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source}), parent_id: #{inspect(state.tree_position.parent_id)}, parent_name: #{inspect(state.tree_position.parent_name)}, depth: #{state.depth}"
    )
  end

  @impl true
  def terminate(_reason, state) do
    # Stop any outstanding queries (children in
    # `pending_children`) before teardown. Defensive against
    # the case where the supervisor gave up because we
    # crashed: we still want in-flight queries cut off. Idle
    # specialists are left running.
    SubAgent.cascade_terminate(state)

    # Cleanup /tmp per design specification
    cleanup_tmp(state.name)

    # Note: workspace is preserved for review/debugging (per design)
    :ok
  end

  @impl true
  def handle_cast(msg, state), do: Callbacks.handle_cast(msg, state)

  @impl true
  def handle_call(msg, from, state), do: Callbacks.handle_call(msg, from, state)

  @impl true
  def handle_info(msg, state), do: Callbacks.handle_info(msg, state)

  # Private functions

  # Clean up the per-agent tmp directory and parent if empty.
  # Delegates to `Nest.Agents.Agent.TmpSpace.cleanup/1` so this
  # module doesn't carry the boilerplate.
  defp cleanup_tmp(agent_id), do: TmpSpace.cleanup(agent_id)

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
  end

  # Public-for-Handlers: message-construction logic. The
  # canonical impl lives in `Nest.Agents.Agent.TmpSpace`; the
  # `__` prefix marks these as internal. See that module for
  # why.
  @doc false
  defdelegate __create_tmp_space__(agent_id), to: TmpSpace, as: :create

  @doc false
  # In-process variant of `handle_call({:append_message, _})`.
  # Returns `{stamped_message, new_state}`.
  @spec __append_message__(t(), {atom(), map()}) :: {term(), t()}
  defdelegate __append_message__(state, message), to: MessageAppender, as: :append_one

  @doc false
  # In-process batch append. Returns `{stamped_messages, new_state}`.
  @spec __append_messages__(t(), [{atom(), map()}]) :: {[term()], t()}
  defdelegate __append_messages__(state, messages), to: MessageAppender, as: :append_in_process

  @doc false
  @spec stamped_index(term()) :: non_neg_integer()
  defdelegate stamped_index(message), to: Callbacks
end
