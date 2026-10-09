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
  Apply the load-time sequence heal in the *caller's* DB context.

  `Persistence.build_attrs_for_start/2` classifies the restored active
  slice and puts the heal in `:load_heal` — either a trailing orphan
  `tool_use` (a turn that died mid-tool) or the user-tail bridge (see
  `Init.LoadHeal`). Applying it appends and persists real rows through the
  canonical append path, so it MUST run in a pid with DB access: the
  caller's, before `GenServer.start_link/1`. It must never run in `init/1`
  (see the hard rule there).

  Idempotent: the classification is re-derived from a fresh read
  immediately before the append (`Init.LoadHeal.refresh/1`), so a caller
  that raced another one for the same tail appends nothing.

  Returns `attrs` with the healed rows folded into `:preloaded_messages`
  and `:load_heal` cleared, so the child only has to seed from attrs. A
  caller whose tail is already healed gets
  the freshly-read attrs back instead (nothing appended), and `attrs`
  unchanged when the agent row is gone or the model no longer resolves —
  the latter boots `init/1` in `:model_missing`, matching the
  pre-refactor behavior.
  """
  @spec pre_load_heal(map()) :: map()
  def pre_load_heal(attrs) do
    case Map.get(attrs, :load_heal) do
      nil -> attrs
      _heal -> heal_if_still_needed(attrs)
    end
  end

  # Idempotent heal: `Init.LoadHeal.refresh/1` re-derives the
  # classification from a fresh read, so a caller that lost a race for the
  # same tail sees `load_heal: nil` and starts its child from the freshly
  # read rows instead of appending a second heal. See that function for why
  # the re-check is preferred over serialization.
  defp heal_if_still_needed(attrs) do
    case Init.LoadHeal.refresh(attrs) do
      nil -> attrs
      %{load_heal: nil} = fresh -> fresh
      %{load_heal: heal} = fresh -> apply_load_heal(fresh, heal)
    end
  end

  defp apply_load_heal(attrs, heal) do
    case Config.create_client_config(Map.fetch!(attrs, :model)) do
      {:ok, client_config} ->
        state = build_active_state(attrs, client_config)
        healed = Init.LoadHeal.heal(state, heal)
        healed_attrs(attrs, state, healed)

      {:error, _reason} ->
        attrs
    end
  end

  # Fold the rows the heal appended (already persisted by the append
  # path) into the attrs the child seeds from, so `init/1` reconstructs
  # the healed sequence without any DB work of its own. The index is not
  # carried here: `Init.seed_from_db/4` recomputes `highest_index + 1`
  # from `:preloaded_messages`, and `Persistence.insert_agent/1` (the
  # only reader of an attrs `:next_message_index`) only ever runs for a
  # brand-new agent via `pre_spawn/1`.
  defp healed_attrs(attrs, before, healed) do
    appended = Enum.drop(healed.chat_state.messages, length(before.chat_state.messages))

    attrs
    |> Map.put(:preloaded_messages, Map.get(attrs, :preloaded_messages, []) ++ appended)
    |> Map.put(:load_heal, nil)
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
    # The clone starts from the parent LLM-facing context: the visible
    # `messages` only. The archived slice is not part of any context - it is
    # derived on demand (`Persistence.load_history/2`) and it contains the
    # non-LLM-visible `{:compaction, _}` marker row, which is exactly how a
    # marker used to end up in a child context.
    shared_prefix = parent_state.chat_state.messages
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
      # The child inherits the shared sequence boundary: below `F`
      # belong to ancestors, and the partition must file the ancestor
      # marker (and everything it archived) as archived here too.
      last_compaction_index: Map.get(parent_state.chat_state, :last_compaction_index, -1),
      compaction_count: Map.get(parent_state.chat_state, :compaction_count, 0),
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

  `sender` identifies the human behind the message (the channel passes
  the socket's username). It is recorded on a queued inbox entry so the
  delivered prompt names the sender; it is ignored for an idle agent,
  which starts the turn immediately. When the agent is busy the message
  and the requested `mode` are queued and delivered at the next turn
  boundary instead of being dropped.
  """
  @spec chat(pid(), String.t(), String.t() | nil, String.t() | nil) :: :ok
  def chat(pid, content, mode \\ nil, sender \\ nil) do
    GenServer.cast(pid, {:chat, content, mode, sender})
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

    Nest.ProjectConfig.apply_or_default(caps, state.workspace_path, state.tmp_path)
  end

  def resolve_caps(%__MODULE__{} = state) do
    Nest.ProjectConfig.apply_or_default(
      Nest.Sandbox.default_caps(),
      state.workspace_path,
      state.tmp_path
    )
  end

  def resolve_caps(_), do: Nest.Sandbox.default_caps()

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
  # Pure: no DB access at all. The caller pre-persists the agent row
  # and the system message (`pre_spawn/1`) and applies the load-time
  # sequence heal (`pre_load_heal/1`) in its own DB context, so this
  # child pid's `init/1` never needs `$callers` propagation back to a
  # Sandbox owner. See the hard rule in `init/1`.
  defp build_active_state(attrs, client_config) do
    state = Init.build_state(attrs, client_config)

    Init.seed_from_db(
      state,
      Map.get(attrs, :preloaded_messages, []),
      Map.get(attrs, :last_compaction_index, -1),
      Map.get(attrs, :compaction_count, 0)
    )
  end

  defp log_active_start(state) do
    Logger.info(
      "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.live.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source}), parent_id: #{inspect(state.tree_position.parent_id)}, parent_name: #{inspect(state.tree_position.parent_name)}, depth: #{state.depth}"
    )
  end

  @impl true
  def terminate(_reason, state) do
    # An owed reply cannot be given up from here (the notices need a live
    # settle): it is lost with the process, so say so in the log.
    Inbox.log_lost_replies(state)

    # Stop any outstanding queries (children in
    # `pending_children`) before teardown. Defensive against
    # the case where the supervisor gave up because we
    # crashed: we still want in-flight queries cut off. Idle
    # specialists are left running.
    SubAgent.cascade_terminate(state)

    # Stop background shell jobs before their tmp log dir is removed, so
    # a running job can't recreate files under a just-deleted directory.
    stop_shell_jobs(state)

    # Cleanup /tmp per design specification
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

  defp stop_shell_jobs(state) do
    ShellJobs.stop_all({state.space_id, state.name})
  catch
    # The manager may be down/restarting during a crash teardown; that
    # must not turn agent shutdown into a raise.
    :exit, _ -> :ok
  end

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
