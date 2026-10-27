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
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.PreSpawn
  alias Nest.Agents.Agent.Shutdown
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.Registry
  alias Nest.Agents.SpaceGate
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Sandbox.Mounts

  defstruct [
    :name,
    :space_id,
    :model,
    :client_config,
    :vocation_id,
    :vocation,
    :tools,
    :llm_metrics,
    :created_by_user_id,
    # The agent's sandbox: the backend its space runs plus the two
    # directories it binds — the workspace and the agent's own scratch
    # directory. One value rather than three fields, because that is what
    # every caller passes to `Nest.Sandbox` and `Nest.Tools.ShellCmd`
    # (`Mounts.from_agent/1` is the one accessor), and because the
    # workspace and the scratch directory are only ever used together.
    # Built once at init from the space's environment. `WorkspaceHandler`
    # moves all three when the space changes; there is no per-agent
    # workspace to move on its own.
    mounts: %Nest.Sandbox.Mounts{workspace: nil, scratch: nil},
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
    # The space's context-warnings setting, read at init into the machine's `ctx`
    # and never onto the mounts: nothing about it reaches a command.
    context_warnings: false,
    # `tree_position` is `%__MODULE__.TreePosition{}` for child agents
    # (carrying `parent_id` + `parent_name`) and the default (both `nil`)
    # for root agents: a sub-struct, so the top-level `Agent` stays within
    # the 16-field cap (`Credo.Check.Warning.StructFieldAmount`).
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
          mounts: Mounts.t(),
          tools: [Nest.LLM.Tool.t()],
          llm_metrics: __MODULE__.LlmMetrics.t(),
          tree_position: __MODULE__.TreePosition.t(),
          created_by_user_id: integer() | nil,
          shared: boolean(),
          depth: non_neg_integer(),
          context_warnings: boolean(),
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
  @spec build_child_attrs(
          map(),
          String.t(),
          String.t(),
          integer(),
          map() | nil,
          String.t() | nil
        ) :: map()
  defdelegate build_child_attrs(
                parent_state,
                instruction,
                child_name,
                parent_id,
                model_override \\ nil,
                mode \\ nil
              ),
              to: PreSpawn

  @doc """
  Sends a chat message to the agent.

  The message is added to the chain and triggers a streaming response from the
  LLM. Responses are broadcast via PubSub to all subscribers.

  The optional `mode` selects the sandbox capability profile for this message's
  tool calls. When `nil`, the agent keeps the mode it is in (`state.live.mode`); a
  name this build does not implement resolves to `Nest.Modes.default/0`.

  `sender` identifies the human behind the message (the channel passes the
  socket's username). It is recorded on a queued inbox entry so the delivered
  prompt names the sender; it is ignored for an idle agent, which starts the
  turn immediately. When the agent is busy the message and the requested `mode`
  are queued and delivered at the next turn boundary instead of being dropped.
  `human?` says whether the content is the human's own words: only then is it tagged
  `origin: "human"` for the Ctrl/Cmd+Up recall list; a spawn's `query` kickoff is not.
  """
  @spec chat(pid(), String.t(), String.t() | nil, String.t() | nil, boolean()) :: :ok
  def chat(pid, content, mode \\ nil, sender \\ nil, source \\ false) do
    GenServer.cast(pid, {:chat, content, mode, sender, source})
  end

  @doc """
  Deliver an async agent-to-agent message to this agent. `kind` is the entry's
  provenance (`Inbox.t:kind/0`): `:agent` for another agent's words, `:query`
  for `agents-query` (which obliges this agent to answer), and `:runtime` for the
  runtime speaking for itself, which no agent said.
  Returns `{:ok, :delivered}` for an idle target, `{:ok, :queued}` for a busy
  one, `{:error, reason}` for a broken target or a full inbox.
  `mode` is the mode the *recipient* is asked to move to, or `nil` for a message
  that asks for no change. It rides the message because the change and the
  instruction that depends on it belong together: the recipient applies it when
  the message is delivered (never mid-turn), and the send tools have already
  checked that the sender may ask (`Nest.Agents.Agent.ModeAuthority`).
  """
  @spec deliver_note(pid(), String.t(), String.t(), Inbox.kind(), String.t() | nil) ::
          {:ok, :delivered | :queued} | {:error, term()}
  def deliver_note(pid, sender, content, kind \\ :agent, mode \\ nil) do
    GenServer.call(pid, {:deliver_async, sender, content, kind, mode}, 5_000)
  end

  @doc """
  Deliver the runtime's own result to this agent, from the process that produced
  it — a batch coordinator enqueueing its aggregate. `kind` is the entry's
  provenance (`Inbox.t:kind/0`); the coordinator passes `:runtime`, because the
  runtime is speaking, not an agent.

  Unlike `deliver_note/4` this is never refused by the peer-inbox cap: the cap
  bounds a runaway *peer* producer, and this is the agent's own result (the same
  guarantee `Inbox.enqueue_internal/6` gives an in-process caller). Returns
  `{:ok, :delivered}` for an idle target, `{:ok, :queued}` otherwise.
  """
  @spec deliver_internal(pid(), String.t() | nil, String.t(), Inbox.kind()) ::
          {:ok, :delivered | :queued}
  def deliver_internal(pid, sender, content, kind) do
    GenServer.call(pid, {:deliver_internal, sender, content, kind}, 5_000)
  end

  @doc """
  Tell this agent that one of its background shell jobs exited (issue #163).

  A **cast**, not a call: the sender is `Nest.Sandbox.ShellJobs`, which must
  never block on an agent to finish a job. The agent enqueues the notice
  (`Nest.Agents.Agent.ShellJobNotice`, `Inbox.enqueue_notice/2`) as a `:runtime`
  entry and drains it when it is idle, so an agent that never called
  `shell-wait` is still woken by its job's result.
  """
  @spec shell_job_exited(pid(), String.t(), integer(), binary()) :: :ok
  def shell_job_exited(pid, job_id, code, output) do
    GenServer.cast(pid, {:shell_job_exited, job_id, code, output})
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
  Cancel this agent's in-flight tool work, because its space's environment
  changed under it.

  A tool worker that is running a command stops it and reports a **tool error**
  (`Nest.Tools.ShellCmd`'s `{:cancel_tool, _}` clause) instead of a result, so the
  turn continues and the agent can see what happened. Nothing is killed: the turn,
  its transcript and the replies it owes are untouched — only the work that cannot
  survive the change.

  The caller is `Nest.Spaces.update_environment/2`, between taking the space's
  `Nest.Agents.SpaceGate` latch and writing the row, so nothing can start in the
  window the cancellation opens.
  """
  @spec cancel_tools(pid(), String.t()) :: :ok
  def cancel_tools(pid, reason) when is_pid(pid) and is_binary(reason) do
    GenServer.call(pid, {:cancel_tools, reason}, :infinity)
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
  @doc """
  Tell a live agent that its space's environment changed.

  `values` is `Nest.Spaces.environment_values/1`: the workspace, the network
  access and the backend now in force. The agent moves its mounts, rebuilds its
  tool closures from them, and appends a notice pair — see
  `Nest.Agents.Agent.WorkspaceHandler`.
  """
  @spec space_changed(pid(), map()) :: :ok
  def space_changed(pid, values) when is_pid(pid) and is_map(values) do
    GenServer.cast(pid, {:space_changed, values})
  end

  @spec set_model(pid(), map()) :: :ok | {:error, term()}
  def set_model(pid, new_model), do: GenServer.call(pid, {:set_model, new_model}, :infinity)

  # Change the agent's model (and thinking level). Handler: `ModelHandler`.
  # The working directory is not here: it is a space property, so it is edited
  # on the space.
  @spec edit_agent(pid(), map()) :: :ok | {:error, term()}
  def edit_agent(pid, model), do: GenServer.call(pid, {:edit_agent, model}, :infinity)

  @doc """
  Resolve the agent's current effective sandbox caps from its state.

  The caps are the mode's — `Nest.Modes.caps/1` — resolved through
  `Nest.ProjectConfig.resolve_caps/2`, so bookkeeping file access (policy stats,
  the `.nest` read) is authorized by the same caps the tools run under. The mode
  is read from `live.mode`, which is the row's mode and can change while the agent
  works. (`AGENTS.md` is not in that set: it is a host read, not a sandboxed one.)

  `Nest.Modes.caps/1` is total: a mode name this build does not implement — a row
  written by another build, a client that made one up — resolves to the default
  mode's caps rather than to nothing. Falling back to
  `Nest.Sandbox.default_caps/0` instead would be *stricter* than the agent's own
  tools, which is the one thing this must not be: the same mode has to authorize
  both.
  """
  @spec resolve_caps(t()) :: map()
  def resolve_caps(%__MODULE__{vocation: %Nest.Vocations.Vocation{}} = state) do
    state.live.mode
    |> Nest.Modes.caps()
    |> Nest.ProjectConfig.resolve_caps(Mounts.from_agent(state))
  end

  def resolve_caps(%__MODULE__{} = state) do
    state.live.mode
    |> Nest.Modes.caps()
    |> Nest.ProjectConfig.resolve_caps(Mounts.from_agent(state))
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

    # The space's before-starts latch: a turn that arrives while the space is
    # being edited is queued rather than started
    # (`Callbacks.chat_or_queue/5`), and the unlock is what wakes it
    # (`Callbacks.handle_info({:space_unlocked, _})`). Subscribed once, here, so a
    # deferral cannot subscribe a second time — PubSub does not deduplicate.
    Phoenix.PubSub.subscribe(Nest.PubSub, SpaceGate.topic(attrs.space_id))

    do_init(attrs)
  end

  defp do_init(attrs) do
    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)

    case Config.create_client_config(model) do
      {:ok, client_config} ->
        state = Init.build_active_state(attrs, client_config)
        announce_pending_space_change(attrs)

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

  # The space changed while this agent was stopped: `init/1` may not touch the DB,
  # so it hands the announcement to a message it sends itself, and the notice is
  # appended from the mounts it just started with — already the space's current
  # values. `Nest.Spaces.update_environment/2` sets the flag on every agent in the
  # space, live or not.
  defp announce_pending_space_change(attrs) do
    if attrs[:space_notice_pending], do: send(self(), :space_notice_pending)
    :ok
  end

  defp log_active_start(state) do
    Logger.info(
      "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.live.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source}), parent_id: #{inspect(state.tree_position.parent_id)}, parent_name: #{inspect(state.tree_position.parent_name)}, depth: #{state.depth}"
    )
  end

  @impl true
  def terminate(reason, state), do: Shutdown.run(reason, state)

  @impl true
  def handle_cast(msg, state), do: Callbacks.handle_cast(msg, state)

  @impl true
  def handle_call(msg, from, state), do: Callbacks.handle_call(msg, from, state)

  @impl true
  def handle_info(msg, state), do: Callbacks.handle_info(msg, state)

  # Public-for-Handlers: message-construction logic. The
  # canonical impl lives in `Nest.Agents.Agent.TmpSpace`; the
  # `__` prefix marks these as internal. See that module for
  # why.
  @doc false
  defdelegate __create_tmp_space__(space_id, agent_name, backend), to: TmpSpace, as: :create

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
