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
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.ClientAPI
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.IntrospectionHandler
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.Restore
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.Registry
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Assistant
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

  @doc """
  Change the agent's resolved LLM client (`client_config`)
  and persisted `model` map. See
  `Nest.Agents.Agent.IntrospectionHandler` for the handler.
  """
  @spec set_model(pid(), map()) :: :ok | {:error, term()}
  def set_model(pid, new_model), do: GenServer.call(pid, {:set_model, new_model}, :infinity)

  defp send_and_ok(pid, msg) do
    send(pid, msg)
    :ok
  end

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

  @doc """
  Returns public information about the agent for the WebSocket
  protocol. Returns a map with :id, :model, :message_count,
  :status, :vocation_id, :partial, :parent_id, :parent_name,
  :depth, :descendant_usage, and :total_usage.

  Re-export of `ClientAPI.get_public_info/1` so existing call
  sites and `@spec`s continue to work.
  """
  defdelegate get_public_info(pid), to: ClientAPI

  @doc """
  Returns the combined usage map for the agent: `usage_totals +
  descendant_usage`, computed field-by-field. Mirrors the
  JS-side chip rendering for "total tokens used".

  Re-export of `ClientAPI.get_total_usage/1`.
  """
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

  # Server Callbacks

  @impl true
  def init(attrs) do
    # Trap exits to ensure cleanup runs when agent is stopped
    Process.flag(:trap_exit, true)

    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)

    case Config.create_client_config(model) do
      {:ok, client_config} ->
        state = build_active_state(attrs, client_config)
        log_active_start(state)
        {:ok, state}

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

        {:ok, build_recovery_state(attrs, model, reason)}
    end
  end

  # Happy-path state construction: build from attrs, hydrate
  # the persisted message sequence, replay the api_log, then
  # log a structured start banner. Extracted from `init/1`
  # so the top-level case statement stays readable.
  defp build_active_state(attrs, client_config) do
    state = Init.build_state(attrs, client_config)

    state =
      Init.seed_from_db(
        state,
        Map.get(attrs, :preloaded_messages, []),
        Map.get(attrs, :last_compaction_index, -1)
      )

    state =
      Restore.attach_rebuilt_api_logs(
        state,
        Map.get(attrs, :preloaded_messages, []),
        Map.get(attrs, :last_compaction_index, -1)
      )

    Init.persist_initial_system_message(state)
    state
  end

  defp log_active_start(state) do
    Logger.info(
      "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source}), parent_id: #{inspect(state.parent_id)}, parent_name: #{inspect(state.parent_name)}, depth: #{state.depth}"
    )
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

  # Sub-agent: child finished its turn. Merge usage, drop the
  # pending-child entry, forward the result, broadcast status.
  @impl true
  def handle_cast({:child_completed, child_name, response, child_total_usage}, state) do
    SubAgent.handle_child_completed(state, child_name, response, child_total_usage)
  end

  # ChatTurn finished unwinding from a user-initiated stop.
  # The ChatTurn casts this from `Lifecycle.stop_chat/2`'s
  # cleanup — it doesn't wait for a reply (the Agent's
  # `chat_stopped/1` does DB I/O). Delegated to the existing
  # `ChatTurnHandler.chat_stopped/2` via `Handlers.handle/2`'s
  # `route_for/1` — but `handle_cast` doesn't go through
  # `Handlers`, so we delegate directly.
  @impl true
  def handle_cast({:chat_stopped, chat_turn_pid}, state) do
    Handlers.ChatTurnHandler.handle({:chat_stopped, chat_turn_pid}, state)
  end

  # Defense-in-depth: drop messages while busy. See channel layer.
  @impl true
  def handle_cast({:chat, content}, state), do: chat_or_drop(state, content, nil)
  @impl true
  def handle_cast({:chat, content, mode}, state), do: chat_or_drop(state, content, mode)

  defp chat_or_drop(state, _content, _mode)
       when state.chat_state.status in [:streaming, :executing_tools, :model_missing],
       do: {:noreply, state}

  defp chat_or_drop(state, content, mode), do: ChatPipeline.handle_chat(state, content, mode)

  # Construct the `:model_missing` recovery state. The
  # implementation lives in `Init.Recovery` so the GenServer
  # module stays under the credo 500-line cap.
  defp build_recovery_state(attrs, model, reason) do
    Init.Recovery.build(attrs, model, reason)
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
  #
  # Both single and batch variants delegate to
  # `Nest.Agents.Agent.MessageAppender` so the loop-breaker
  # reset and `__append_message__/2` reuse logic lives in one
  # place. The batch variant exists for the Case 2 notice-pair
  # injectors (see `Nest.Agents.Agent.NoticePairInjector`).
  @impl true
  def handle_call({:append_message, message}, _from, state) do
    {stamped, state} = MessageAppender.handle_single(state, message)
    {:reply, stamped, state}
  end

  @impl true
  def handle_call({:append_messages, messages}, _from, state) do
    {stamped, state} = MessageAppender.handle_batch(state, messages)
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

  # User clicked Stop. Synchronously mark the in-flight
  # ChatTurn as cancelled and tell it to do the actual stop
  # work (kill worker, ack the channel, send `:chat_stopped`
  # to ourselves, stop). The `cancelled` flag is set FIRST
  # so any concurrent `GenServer.call(:get_messages_with_cancelled)`
  # from the ChatTurn's `handle_info` clauses sees the flag
  # after this `handle_call` returns. The call to the
  # ChatTurn uses a 5s timeout to break the rare deadlock
  # where the ChatTurn is itself blocked on
  # `safe_iterate/1`'s `GenServer.call(agent, ...)` — the
  # ChatTurn's `iterate/1` catches the exit and stops cleanly.
  @impl true
  def handle_call({:stop_chat, channel_pid}, _from, state) do
    state = %{state | chat_state: %{state.chat_state | cancelled: true}}

    if chat_turn_pid = state.chat_state.chat_turn_pid do
      try do
        GenServer.call(chat_turn_pid, {:stop_chat, channel_pid}, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:reply, :ok, state}
  end

  # Catch-all dispatcher for introspection calls.
  @impl true
  def handle_call(msg, from, state) do
    IntrospectionHandler.handle(msg, from, state)
  end

  @doc false
  # In-process variant of `handle_call({:append_message, _})`
  # for callers that don't want the mailbox round-trip.
  # Delegates to `Nest.Agents.Agent.MessageAppender.append_one/2`
  # which owns the stamp + broadcast + persist logic.
  #
  # Returns `{stamped_message, new_state}`.
  @spec __append_message__(t(), {atom(), map()}) :: {term(), t()}
  defdelegate __append_message__(state, message), to: MessageAppender, as: :append_one

  @doc false
  # In-process batch append. Same atomicity guarantee as
  # the `{:append_messages, _}` GenServer.call handler
  # without paying the round-trip cost for callers that
  # already run inside the Agent process (e.g. the
  # user-message pipeline injection). Delegates to
  # `Nest.Agents.Agent.MessageAppender.append_in_process/2`.
  #
  # Returns `{stamped_messages, new_state}`.
  @spec __append_messages__(t(), [{atom(), map()}]) :: {[term()], t()}
  defdelegate __append_messages__(state, messages), to: MessageAppender, as: :append_in_process

  # Extract the index from a stamped message tuple. Exposed
  # so in-process callers can read back the stamped index
  # without re-doing the pattern match.
  @doc false
  @spec stamped_index(term()) :: non_neg_integer()
  def stamped_index({_role, %{index: index}}), do: index

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
