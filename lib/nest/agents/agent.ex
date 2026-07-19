defmodule Nest.Agents.Agent do
  @moduledoc """
  GenServer that manages an individual agent's state and chat.

  Each agent runs as an independent process with:
  - A unique readable name (e.g., "clever-raven")
  - Message history with tool calling support
  - LLM client config for model communication
  - Streaming broadcast support for real-time responses via PubSub
  """

  use GenServer, restart: :temporary

  require Logger

  alias Nest.Agents.Agent.ApiLogs
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.IntrospectionHandler
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.Registry
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  defstruct [
    :name,
    :model,
    :client_config,
    :vocation_id,
    :vocation,
    :workspace_path,
    :tmp_path,
    :tools,
    :llm_metrics,
    # `parent_id` is the integer `agents.id` of the agent that
    # spawned this one via the `clone_agent` tool. `nil` for
    # root agents. The corresponding Pubsub topic identity is
    # the parent's `name` (a String); we keep the integer FK
    # here so the persisted row carries the relationship and
    # we can rebuild the tree after a BEAM restart.
    :parent_id,
    # `parent_name` is the parent's readable identifier
    # (`String.t()`). Held as runtime state only (not
    # persisted) so the child can dispatch messages to the
    # parent's GenServer through `Agents.Registry.via_tuple/1`
    # without an integer→name lookup at completion time. The
    # integer FK above is the durable identifier.
    :parent_name,
    mode: "chat",
    # `depth` is the agent's distance from its tree root.
    # 0 = root (no parent). Children of a depth-D parent are
    # depth D+1. The `clone_agent` tool is only available when
    # `depth < configured_max_depth()`, so a depth-D agent
    # can spawn children of depth D+1 (provided D+1 < max).
    # Persisted via `agents.depth` so the value survives a
    # BEAM restart and the system-prompt composition can
    # honor it from `init/1`.
    depth: 0,
    chat_state: %__MODULE__.ChatState{}
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
          model: map(),
          client_config: ClientConfig.t(),
          vocation: Vocations.Vocation.t(),
          workspace_path: String.t() | nil,
          tmp_path: String.t() | nil,
          tools: [Nest.LLM.Tool.t()],
          llm_metrics: __MODULE__.LlmMetrics.t(),
          parent_id: integer() | nil,
          parent_name: String.t() | nil,
          depth: non_neg_integer(),
          mode: String.t(),
          chat_state: __MODULE__.ChatState.t()
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

  The agent registers itself in the Registry under its name.
  """
  @spec start_link(attrs :: map()) :: GenServer.on_start()
  def start_link(attrs) do
    name = Map.fetch!(attrs, :name)
    GenServer.start_link(__MODULE__, attrs, name: Registry.via_tuple(name))
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
  channel pid that initiated the stop (used so the agent can
  reply `{:reply, :ok, ...}` via the GenServer mailbox). A no-op
  when idle; idempotent.
  """
  @spec stop_chat(pid(), pid()) :: :ok
  def stop_chat(pid, from \\ self()) do
    send(pid, {:stop_chat, from})
    :ok
  end

  @doc """
  Re-run the compactor after a `:compaction_failed` status.
  Handler no-ops when the agent isn't in `:compaction_failed`.
  """
  @spec retry_compaction(pid()) :: :ok
  def retry_compaction(pid), do: send_and_ok(pid, :retry_compaction)

  @doc """
  Acknowledge a `:compaction_loop_detected` status. Handler
  no-ops when the agent isn't in that status.
  """
  @spec compaction_loop_detected_ok(pid()) :: :ok
  def compaction_loop_detected_ok(pid),
    do: send_and_ok(pid, :compaction_loop_detected_ok)

  defp send_and_ok(pid, msg) do
    send(pid, msg)
    :ok
  end

  @doc """
  Test-only: returns the pid of the in-flight ChatTurn (or
  `nil` if the agent is idle). Production code should use
  `stop_chat/2` instead.
  """
  @spec get_chat_turn_pid(pid()) :: pid() | nil
  def get_chat_turn_pid(pid) do
    GenServer.call(pid, :get_chat_turn_pid)
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

  Returns a map with :id, :model, :message_count, :status, :vocation_id,
  :partial, :parent_id, :parent_name, :depth, :descendant_usage, and
  :total_usage.
  """
  @spec get_public_info(pid()) :: %{
          id: String.t(),
          model: map(),
          message_count: non_neg_integer(),
          status: atom(),
          vocation_id: integer() | nil,
          tmp_path: String.t() | nil,
          partial: map() | nil,
          parent_id: integer() | nil,
          parent_name: String.t() | nil,
          depth: non_neg_integer(),
          descendant_usage: map() | nil,
          total_usage: map() | nil
        }
  def get_public_info(pid) do
    GenServer.call(pid, :get_public_info)
  end

  @doc """
  Returns the combined usage map for the agent: `usage_totals +
  descendant_usage`, computed field-by-field. Returns `nil` when
  either side is `nil` (an uninitialized state).

  Mirrors the JS-side chip rendering for "total tokens used"
  (the cumulative spend across this agent and its descendants).
  The split between direct and total is what the UI's token
  chip displays — direct is `usage_totals`, total is this
  function.
  """
  @spec get_total_usage(pid()) :: map() | nil
  def get_total_usage(pid) do
    GenServer.call(pid, :get_total_usage)
  end

  @doc """
  Returns the message history for the agent.
  """
  @spec get_messages(pid()) :: [Message.t()]
  def get_messages(pid) do
    GenServer.call(pid, :get_messages)
  end

  @doc """
  Returns the archived history (compacted-away messages plus
  `{:compaction, _}` markers between them) for the agent.

  The full sequence visible to the UI is `get_history(agent) ++
  get_messages(agent)`.
  """
  @spec get_history(pid()) :: [Message.t()]
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  # Server Callbacks

  @impl true
  def init(attrs) do
    # Trap exits to ensure cleanup runs when agent is stopped
    Process.flag(:trap_exit, true)

    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)

    case Config.create_client_config(model) do
      {:ok, client_config} ->
        state = Init.build_state(attrs, client_config)

        # If the Supervisor passed a `:preloaded_messages` list
        # (the on-demand-load path), partition it at
        # `last_compaction_index` into `state.chat_state.messages`
        # and `state.chat_state.history`, and bump
        # `next_message_index` to one past the highest stamped
        # index. The preloaded list is already `message_index`-
        # sorted by `Persistence.load_messages/1`.
        state =
          Init.seed_from_db(
            state,
            Map.get(attrs, :preloaded_messages, []),
            Map.get(attrs, :last_compaction_index, -1)
          )

        # Replay the request-payload build for every `:user`
        # and `:tool` message so the agent's API log history
        # survives a BEAM restart. The rebuilt logs match the
        # wire format `Broadcasts.api_log/4` would have produced
        # for the same message slice, and live requests after
        # restore pick up at `.001` (no id collision). Idempotent
        # with respect to messages that already carry non-empty
        # api_logs; today the rebuild is the only writer for
        # user/tool api_logs.
        state =
          Init.attach_rebuilt_api_logs(
            state,
            Map.get(attrs, :preloaded_messages, []),
            Map.get(attrs, :last_compaction_index, -1)
          )

        Init.persist_initial_system_message(state)

        Logger.info(
          "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source}), parent_id: #{inspect(state.parent_id)}, parent_name: #{inspect(state.parent_name)}, depth: #{state.depth}"
        )

        {:ok, state}

      {:error, reason} ->
        cleanup_tmp(name)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Cascade-stop any registered children. The
    # `ChildRegistry` walks by name (no pid work); the
    # `Supervisor` then tears down each child via its own
    # `terminate/2`. Defensive against the case where the
    # supervisor gave up because we crashed: we still
    # want children cleaned up.
    SubAgent.cascade_terminate(state)

    # Cleanup /tmp per design specification
    cleanup_tmp(state.name)

    # Note: workspace is preserved for review/debugging (per design)
    :ok
  end

  @impl true
  def handle_cast({:chat, content}, state) do
    ChatPipeline.handle_chat(state, content, nil)
  end

  @impl true
  def handle_cast({:chat, content, mode}, state) do
    ChatPipeline.handle_chat(state, content, mode)
  end

  # Sub-agent: a child has finished its turn. Its
  # GenServer (see `chat_idle` handler) cast this message
  # up the tree carrying the child's last assistant content
  # and the child's total usage (already inclusive of any
  # grandchildren). We merge the usage into our
  # `descendant_usage`, drop the pending-child entry, send
  # the `:clone_agent_result` to the worker that's been
  # blocked on the parent side of the call, and broadcast
  # the updated status (so the UI's token chip picks up the
  # new total).
  @impl true
  def handle_cast({:child_completed, child_name, response, child_total_usage}, state) do
    SubAgent.handle_child_completed(state, child_name, response, child_total_usage)
  end

  # Test-only helpers for asserting on the loop-breaker counter.
  # Production callers should not need these — the counter is
  # managed internally by `CompactionHandler.check_consecutive/1`
  # Introspection handle_calls (`:get_*` etc.) live in
  # Introspection handle_calls (`:get_*` etc.) live in
  # `IntrospectionHandler`. The clauses below are the
  # message-mutation path (`:append_message`,
  # `:append_compaction_messages`); the catch-all at the
  # bottom dispatches every other tag to
  # `IntrospectionHandler.handle/3`.

  # The canonical message-append path. The Agent is the single
  # writer of `index`: every message — user, assistant, tool
  # result, system reminder — flows through this handler. This
  # closes the dual-counter bug class (the old code had the
  # LLMRunner maintaining its own `state.message_index` counter
  # in parallel with `next_message_index`; the two drifted
  # whenever a side-channel message like a budget reminder was
  # injected, causing the reminder and the next response to
  # share an index).
  @impl true
  def handle_call({:append_message, message}, _from, state) do
    # Reset the loop-breaker counter on genuine progress:
    # appending a user message, the LLM's assistant response,
    # or a successful tool result. `{:system, _}` (context
    # reminders, budget warnings) and `{:compaction, _}`
    # (markers) are bookkeeping, not progress.
    state =
      case message do
        {:user, _} -> reset_consecutive(state)
        {:assistant, _} -> reset_consecutive(state)
        {:tool, _} -> reset_consecutive(state)
        _ -> state
      end

    {stamped, state} = __append_message__(state, message)
    {:reply, stamped, state}
  end

  # Compactor's suffix is now appended by the trigger
  # via `__append_message__/2` before the compactor's
  # chat turn spawns. The LLM's response (the summary)
  # is appended by the LLM stream handler's
  # `tool_calls_received/2` (same path as a regular chat
  # turn). The previous `{:append_compaction_messages, _}`
  # bulk-append is no longer needed.

  # Sub-agent: a tool worker (running in the chat turn) is
  # blocked on the tool dispatch and has hit a `clone_agent`
  # tool call. Spawn a child agent, kick off its chat
  # turn with the supplied instruction, remember the
  # worker's pid so we can forward the eventual
  # `:clone_agent_result`, and reply synchronously with the
  # child's name so the worker can match its `receive` on
  # child identity.
  @impl true
  def handle_call({:clone_agent_request, task_pid, instruction}, _from, state) do
    SubAgent.handle_clone_request(state, task_pid, instruction)
  end

  # Catch-all dispatcher for introspection calls.
  @impl true
  def handle_call(msg, from, state) do
    IntrospectionHandler.handle(msg, from, state)
  end

  defp reset_consecutive(state) do
    %{state | chat_state: %{state.chat_state | consecutive_compaction_count: 0}}
  end

  @doc false
  # In-process variant of `handle_call({:append_message, _})`
  # for callers that don't want the mailbox round-trip. The
  # message is a `{role, %{index: _}}` tuple; the inner
  # struct's `index` is overwritten with
  # `state.chat_state.next_message_index`. Returns
  # `{stamped_message, new_state}`.
  #
  # After stamping and broadcasting, the message is
  # persisted into the `messages` table and the agent's
  # `next_message_index` is bumped on the row. Both writes
  # run in this process, walking `$callers` back to the
  # test's sandboxed connection (or the production pool)
  # without per-pid `Sandbox.allow/3`.
  @spec __append_message__(t(), {atom(), map()}) :: {term(), t()}
  def __append_message__(state, message) do
    index = state.chat_state.next_message_index
    stamped = put_message_index(message, index)

    messages = state.chat_state.messages ++ [stamped]

    state = %{
      state
      | chat_state: %{state.chat_state | messages: messages, next_message_index: index + 1}
    }

    Broadcasts.message(state.name, stamped)
    persist_appended_message(state, stamped)
    {stamped, state}
  end

  # Persist a freshly-appended message. Failures are logged
  # but don't crash the in-memory append — the live state
  # is the source of truth for the current turn; the
  # persisted row is for cross-restart recovery.
  defp persist_appended_message(state, stamped) do
    AgentPersistence.append_message(state.name, stamped, state.chat_state.next_message_index)
  end

  # Extract the index from a stamped message tuple. Exposed
  # so in-process callers can read back the stamped index
  # without re-doing the pattern match.
  @doc false
  @spec stamped_index(term()) :: non_neg_integer()
  def stamped_index({_role, %{index: index}}), do: index

  defp put_message_index({role, %{index: _} = msg}, index) do
    {role, %{msg | index: index}}
  end

  # Compaction completion is now handled in-process by
  # `Nest.Agents.Agent.Compaction.ResultHandler.handle_success/3`
  # (called from `Handlers.CompactionHandler.handle/2` on
  # `{:compaction_done, ...}` arrival). The previous
  # `__compaction_completed__/2` defdelegate (which
  # forwarded to `Compaction.Lifecycle.apply/2`) is
  # removed — the result handler owns the full flow
  # (strip → summary_user → archive → persist →
  # broadcast → spawn next).

  @impl true
  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end

  # Private functions

  # Clean up the per-agent tmp directory and parent if empty.
  # Delegates to `Nest.Agents.Agent.TmpSpace.cleanup/1` so this
  # module doesn't carry the boilerplate.
  defp cleanup_tmp(agent_id), do: TmpSpace.cleanup(agent_id)

  # Public-for-Handlers: message-construction logic. The
  # canonical impl lives in `Nest.Agents.Agent.ApiLogs` /
  # `Nest.Agents.Agent.TmpSpace`; the `__` prefix marks these
  # as internal. See those modules for why.
  @doc false
  defdelegate __pending_api_logs__(state, message_index), to: ApiLogs, as: :get
  defdelegate __clear_pending_api_logs__(state, message_index), to: ApiLogs, as: :clear
  defdelegate __create_tmp_space__(agent_id), to: TmpSpace, as: :create
end
