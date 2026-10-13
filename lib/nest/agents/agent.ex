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
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.Machine.Backgrounding
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.PreSpawn
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.Registry
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs

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
    # `PreSpawn.build_child_attrs/5`).
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
  # constructed by `ChatPipeline.append_and_spawn/2` (via
  # `Turn.start/4`) and lives on the machine's `work.ctx`. The Agent
  # is the storage layer + lifecycle router; the in-process
  # `Nest.Agents.Agent.Turn` drives the iteration.
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
  inserts, and the load-time sequence heal) is the caller's
  responsibility — call `Agent.pre_spawn/1` and
  `Agent.pre_load_heal/1` in the caller's pid before
  `start_link/1`. The supervisor pid (or any pid that wraps
  `start_link/1` via `DynamicSupervisor`) has no DB work to do,
  so it doesn't need a Sandbox checkout.

  The agent registers itself in the Registry under its name.
  """
  @spec start_link(attrs :: map()) :: GenServer.on_start()
  def start_link(attrs) do
    name = Map.fetch!(attrs, :name)
    space_id = Map.fetch!(attrs, :space_id)
    GenServer.start_link(__MODULE__, attrs, name: Registry.via_tuple(space_id, name))
  end

  @doc """
  Pre-spawn DB work for `start_link/1`: inserts the agent row and the
  initial system message (or, for a clone, the rows it owns) in the
  *caller's* DB context. Full contract:
  `Nest.Agents.Agent.PreSpawn.pre_spawn/1`.
  """
  @spec pre_spawn(map()) :: {:ok, integer()} | {:error, term()}
  defdelegate pre_spawn(attrs), to: PreSpawn

  @doc """
  Apply the load-time sequence heal in the *caller's* DB context, before
  `start_link/1`. Idempotent. Full contract:
  `Nest.Agents.Agent.PreSpawn.pre_load_heal/1`.
  """
  @spec pre_load_heal(map()) :: map()
  defdelegate pre_load_heal(attrs), to: PreSpawn

  @doc """
  Build a child agent's attrs from a parent state and the clone
  instruction. Pure data shaping — no DB writes, no spawning. Full
  contract: `Nest.Agents.Agent.PreSpawn.build_child_attrs/5`.
  """
  @spec build_child_attrs(map(), String.t(), String.t(), integer(), map() | nil) :: map()
  defdelegate build_child_attrs(
                parent_state,
                instruction,
                child_name,
                parent_id,
                model_override \\ nil
              ),
              to: PreSpawn

  @doc """
  Sends a chat message to the agent.

  The message is added to the chain and triggers a streaming response from the
  LLM. Responses are broadcast via PubSub to all subscribers.

  The optional `mode` selects the sandbox capability profile for this message's
  tool calls. When `nil`, the agent falls back to its default mode (first key in
  the vocation's `modes` map, or `"chat"` if no modes are defined).

  `sender` identifies the human behind the message (the channel passes the
  socket's username). It is recorded on a queued inbox entry so the delivered
  prompt names the sender; it is ignored for an idle agent, which starts the
  turn immediately. When the agent is busy the message and the requested `mode`
  are queued and delivered at the next turn boundary instead of being dropped.
  `human?` says whether the content is the human's own words: only then is it tagged
  `origin: "human"` for the Ctrl/Cmd+Up recall list; a spawn's `query` kickoff is not.
  """
  @spec chat(pid(), String.t(), String.t() | nil, String.t() | nil, boolean()) :: :ok
  def chat(pid, content, mode \\ nil, sender \\ nil, human? \\ false) do
    GenServer.cast(pid, {:chat, content, mode, sender, human?})
  end

  @doc """
  Deliver an async agent-to-agent message to this agent. `kind` is the entry's
  provenance (`Inbox.t:kind/0`): `:agent` for another agent's words, `:query`
  for `agents-query` (which obliges this agent to answer), and `:notice` for the
  runtime speaking for itself, which no agent said.
  Returns `{:ok, :delivered}` for an idle target, `{:ok, :queued}` for a busy
  one, `{:error, reason}` for a broken target or a full inbox.
  """
  @spec deliver_message(pid(), String.t(), String.t(), Inbox.kind()) ::
          {:ok, :delivered | :queued} | {:error, term()}
  def deliver_message(pid, sender, content, kind \\ :agent) do
    GenServer.call(pid, {:deliver_async, sender, content, kind}, 5_000)
  end

  @doc """
  Deliver the runtime's own result to this agent, from the process that produced
  it — a batch coordinator enqueueing its aggregate. `kind` is the entry's
  provenance (`Inbox.t:kind/0`); the coordinator passes `:notice`, because the
  runtime is speaking, not an agent.

  Unlike `deliver_message/4` this is never refused by the peer-inbox cap: the cap
  bounds a runaway *peer* producer, and this is the agent's own result (the same
  guarantee `Inbox.enqueue_internal/4` gives an in-process caller). Returns
  `{:ok, :delivered}` for an idle target, `{:ok, :queued}` otherwise.
  """
  @spec deliver_internal(pid(), String.t() | nil, String.t(), Inbox.kind()) ::
          {:ok, :delivered | :queued}
  def deliver_internal(pid, sender, content, kind) do
    GenServer.call(pid, {:deliver_internal, sender, content, kind}, 5_000)
  end

  defdelegate register_watch(pid, ref, spec), to: ClientAPI
  defdelegate watch_attached(pid, ref, task_pid), to: ClientAPI
  defdelegate unregister_watch(pid, ref), to: ClientAPI
  defdelegate watch_fired(pid, ref, content), to: ClientAPI

  @doc """
  Signal the in-flight chat turn (if any) to stop. `from` is the
  channel pid that initiated the stop (used so the in-process turn
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

  Synchronous: the channel's `handle_in("chat:retry-compaction", ...)` reply
  lands after the agent has actually handled the retry, not the moment the
  message queued. `GenServer.call/3` with `:infinity` matches `set_model/2`'s
  contract; the retry handler is fast (log + state return) so
  the unbounded wait is fine.
  """
  @spec retry_compaction(pid()) :: :ok
  def retry_compaction(pid), do: GenServer.call(pid, :retry_compaction, :infinity)

  @doc """
  Stage a compaction turn now (the user's `/compact <focus>` command).

  Only valid from `:idle`; the handler replies `{:error, {:not_idle, status}}`
  for any other status without touching the machine. `focus` is the optional
  operator guidance for the summary (`nil` when the command had no args).
  Synchronous so the channel's reply lands after the agent has actually staged
  the compaction.
  """
  @spec compact(pid(), String.t() | nil) :: :ok | {:error, {:not_idle, atom()}}
  def compact(pid, focus), do: GenServer.call(pid, {:compact, focus}, :infinity)

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
    caps =
      case Nest.Vocations.get_caps(vocation, state.live.mode) do
        {:ok, caps} -> caps
        _ -> Nest.Sandbox.default_caps()
      end

    Nest.ProjectConfig.apply_or_default(caps, Mounts.from_agent(state))
  end

  def resolve_caps(%__MODULE__{} = state) do
    Nest.ProjectConfig.apply_or_default(Nest.Sandbox.default_caps(), Mounts.from_agent(state))
  end

  def resolve_caps(_), do: Nest.Sandbox.default_caps()

  @doc """
  Terminates the agent process. Re-export of `ClientAPI.terminate/1`.
  """
  defdelegate terminate(pid), to: ClientAPI

  # The agent's current status, read in the agent's own process. Re-export of
  # `ClientAPI.get_status/2`.
  defdelegate get_status(pid, timeout), to: ClientAPI

  # Returns public agent info for the WebSocket protocol (id, model,
  # message_count, status, vocation_id, partial, parent, usage, ...).
  # Re-export of `ClientAPI.get_public_info/2`; `timeout` defaults to
  # OTP's 5 s.
  defdelegate get_public_info(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the combined usage map for the agent: `usage_totals +
  # descendant_usage`, computed field-by-field. Re-export of
  # `ClientAPI.get_total_usage/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_total_usage(pid, timeout \\ 5_000), to: ClientAPI

  @doc """
  Returns the active message list for the agent.

  Re-export of `ClientAPI.get_messages/2`; `timeout` defaults to OTP's
  5 s.
  """
  defdelegate get_messages(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the parent's outstanding query children (name => true). Re-export
  # of `ClientAPI.get_pending_children/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_pending_children(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the announced context thresholds. Re-export of
  # `ClientAPI.get_crossed_thresholds/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_crossed_thresholds(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the raw children sub-machine (the value `Children.target/2`
  # resolves from). Re-export of `ClientAPI.get_children/2`; `timeout`
  # defaults to OTP's 5 s.
  defdelegate get_children(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the machine's turn-scoped working set. Re-export of
  # `ClientAPI.get_work/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_work(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the LLM client configuration. Re-export of
  # `ClientAPI.get_client_config/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_client_config(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the registered tool closures. Re-export of
  # `ClientAPI.get_tools/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_tools(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the cached Vocation struct. Re-export of
  # `ClientAPI.get_vocation/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_vocation(pid, timeout \\ 5_000), to: ClientAPI

  # Returns the outstanding watch registrations. Re-export of
  # `ClientAPI.get_watches/2`; `timeout` defaults to OTP's 5 s.
  defdelegate get_watches(pid, timeout \\ 5_000), to: ClientAPI

  @doc """
  Fetch API logs for a specific message by index, given the agent's
  derived archive (`Persistence.load_history/2`, resolved by the
  caller so the agent process never reads the DB for display).
  """
  defdelegate get_api_logs(pid, index, history), to: ClientAPI

  # Server Callbacks

  @impl true
  def init(attrs) do
    # ---------------------------------------------------------------------
    # HARD RULE — NO DB ACCESS IN THIS CALLBACK. EVER. FOR ANY REASON.
    #
    # Not a read, not a write, not a "tiny lookup" — `init/1` and every
    # function it calls must be DB-free. This is not a note; it is the
    # rule, and it is not negotiable.
    #
    # Why: `init/1` runs in the pid the *supervisor* spawned. That pid has
    # no Ecto Sandbox `$callers` chain back to whoever owns the connection
    # (the test pid, or the channel/request pid in production), so a DB
    # call here either crashes an async test or silently checks out a
    # different connection inside a caller-owned transaction.
    #
    # All pre-spawn DB work belongs to the CALLER, before `start_link/1`:
    # `Agent.pre_spawn/1` (agent row + system message) and
    # `Agent.pre_load_heal/1` (the load-time sequence heal). `init/1` only
    # builds in-memory state from the attrs it is handed.
    # ---------------------------------------------------------------------
    # Trap exits to ensure cleanup runs when agent is stopped
    Process.flag(:trap_exit, true)

    do_init(attrs)
  end

  defp do_init(attrs) do
    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)

    case Config.create_client_config(model) do
      {:ok, client_config} ->
        state = Init.build_active_state(attrs, client_config)

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

  defp log_active_start(state) do
    Logger.info(
      "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.live.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source}), parent_id: #{inspect(state.tree_position.parent_id)}, parent_name: #{inspect(state.tree_position.parent_name)}, depth: #{state.depth}"
    )
  end

  @impl true
  def terminate(_reason, state) do
    # This callback runs inside the exit handshake the test teardown uses as
    # its idle detector (`Nest.Agents.AgentTestLifecycle.stop_pid/2`): the
    # test's `:DOWN` only arrives once this returns, so time spent here is
    # charged to the handshake and loosens the detector. Keep every step local
    # and cheap, and hand anything that is not needed for the process to die to
    # the process that needs it.

    # An owed reply cannot be given up from here (the notices need a live
    # settle): it is lost with the process, so say so in the log.
    Inbox.log_lost_replies(state)

    # Stop the workers this process's turn is running. They are Tasks under the
    # application-wide `Nest.Agents.TaskSupervisor`, not children of this
    # process, so nothing else here reaches them — `SubAgent.cascade_terminate`
    # below stops children and watchers, and the shell-jobs cast stops jobs.
    # A worker left running past this process keeps doing the turn's work with
    # nothing left to consume it: it runs tool calls of its own, and one of them
    # — `agents-send`/`agents-query` → `Agents.send_message/5` →
    # `Supervisor.get_agent/2`'s on-demand load → `Init.LoadHeal.heal/2` —
    # *appends* a message for the agent it loads, in the worker's own DB
    # context. In a test that context is the test process's sandbox connection,
    # which is checked in as the test process exits: the append then fails with
    # `DBConnection.ConnectionError: owner … exited`, long after the teardown
    # stopped every agent it could see. Death bypasses the turn's Stop
    # transition, which is the only place that kills these today
    # (`Machine.Stopping`'s `{:kill, active_worker}` and
    # `Machine.Backgrounding.kill_actions/1`), so it must stop them itself.
    stop_turn_workers(state)

    # Stop any outstanding queries (children in
    # `pending_children`) before teardown. Defensive against
    # the case where the supervisor gave up because we
    # crashed: we still want in-flight queries cut off. Idle
    # specialists are left running.
    SubAgent.cascade_terminate(state)

    # Ask the shell-jobs manager to stop this agent's jobs. Deliberately the
    # non-blocking form: the manager is a process-global rendezvous that every
    # agent's teardown passes through, so waiting on it here would put a shared
    # process's queue latency inside every agent's exit — the same rendezvous
    # that can leave a dying agent unable to answer a call for hundreds of
    # milliseconds. The manager already monitors this pid (`track_agent/3`), so
    # this cast is not what keeps a job from outliving its agent; it asks for
    # the stop without making the exit wait.
    ShellJobs.stop_all_async({state.space_id, state.name})

    # Cleanup /tmp per design specification. This removal is the *fence* the
    # tmp-path tests rely on — the directory is gone by the time this process's
    # `:DOWN` arrives. It is not the ordering guarantee against a running job:
    # the cast above can still be processed after this line. That guarantee is
    # the manager's, in `ShellJobs.drop_agent/2`: it removes the same directory
    # *after* it has stopped this agent's jobs, so a job cannot recreate files
    # under a just-deleted path and leave them behind.
    cleanup_tmp(state.space_id, state.name)

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

  # Clean up this agent's own tmp sub-directory. Never touches the
  # space directory or a sibling's files. Delegates to
  # `Nest.Agents.Agent.TmpSpace.cleanup/2` so this module doesn't carry
  # the boilerplate.
  defp cleanup_tmp(space_id, agent_name), do: TmpSpace.cleanup(space_id, agent_name)

  # Every worker this process's turn is running: the live one, the batches it
  # moved to the background (`Machine.Backgrounding.pids/1`), and the batch
  # coordinators (`Machine.Children.reporting_targets/1`). All are tasks under
  # the application-wide `Nest.Agents.TaskSupervisor`, not children of this
  # process, and the turn's Stop transition is the only other thing that kills
  # them — a death runs no transition. Distinct pids — one batch can be recorded
  # under two refs, and one coordinator reports for many children.
  #
  # `stop_worker/1` sends the same `{:stop_chat, self()}` handshake the
  # executor's `{:kill, pid}` action does (see `Backgrounding.kill_actions/1`):
  # it is what lets a worker parked in a foreground `shell-cmd` `:exec.stop/1`
  # its bwrap process before it goes. Without it the signal kills the worker
  # while its sandbox process is still running. No wait: this runs inside the
  # exit handshake (see `terminate/2`).
  defp stop_turn_workers(state) do
    machine = state.live.machine

    ([machine.work.active_worker | Backgrounding.pids(machine)] ++
       Children.reporting_targets(machine.children))
    |> Enum.uniq()
    |> Enum.each(&stop_worker/1)
  end

  defp stop_worker(pid) when is_pid(pid) do
    send(pid, {:stop_chat, self()})
    Process.exit(pid, :shutdown)
  end

  defp stop_worker(_none), do: :ok

  # Public-for-Handlers: message-construction logic. The
  # canonical impl lives in `Nest.Agents.Agent.TmpSpace`; the
  # `__` prefix marks these as internal. See that module for
  # why.
  @doc false
  defdelegate __create_tmp_space__(space_id, agent_name), to: TmpSpace, as: :create

  @doc false
  # In-process variant of `handle_call({:append_message, _})`.
  # Returns the tagged append result (see `MessageAppender`).
  @spec __append_message__(t(), {atom(), map()}) :: MessageAppender.append_result()
  defdelegate __append_message__(state, message), to: MessageAppender, as: :append_one

  @doc false
  # In-process batch append. Returns the tagged append result.
  @spec __append_messages__(t(), [{atom(), map()}]) :: MessageAppender.append_result()
  defdelegate __append_messages__(state, messages), to: MessageAppender, as: :append_in_process

  @doc false
  @spec stamped_index(term()) :: non_neg_integer()
  defdelegate stamped_index(message), to: Callbacks
end
