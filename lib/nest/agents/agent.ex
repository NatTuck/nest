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

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction.Lifecycle, as: CompactionLifecycle
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.Registry
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Vocations

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
    mode: "chat",
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
  Signal the in-flight chat task (if any) to stop. The agent's
  `handle_info({:stop_chat, _}, state)` will halt the chat task at
  its next blocking receive, finalize the partial streaming
  accumulator, and broadcast `chat:status: "idle"`. The `from`
  argument is the channel pid that initiated the stop; it is
  passed through so the agent can reply `{:reply, :ok, ...}` to
  the channel push (the reply is sent via the GenServer
  mailbox, not directly).

  A no-op when the agent is idle (no in-flight chat task).
  Idempotent — multiple calls just re-set the `cancelled` flag.
  """
  @spec stop_chat(pid(), pid()) :: :ok
  def stop_chat(pid, from \\ self()) do
    send(pid, {:stop_chat, from})
    :ok
  end

  @doc """
  Test-only: returns the pid of the in-flight ChatTurn (or
  `nil` if the agent is idle). The pid is used by tests to
  inject stop signals directly into the ChatTurn's mailbox,
  bypassing the GenServer mailbox ordering. Production code
  should use `stop_chat/2` instead.
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

  Returns a map with :id, :model, :message_count, :status, :vocation_id, and :partial.
  """
  @spec get_public_info(pid()) :: %{
          id: String.t(),
          model: map(),
          message_count: non_neg_integer(),
          status: atom(),
          vocation_id: integer() | nil,
          tmp_path: String.t() | nil,
          partial: map() | nil
        }
  def get_public_info(pid) do
    GenServer.call(pid, :get_public_info)
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
        # (the on-demand-load path), seed it into the chat state
        # and bump `next_message_index` to one past the highest
        # stamped index. The preloaded list is already
        # `message_index`-sorted by `Persistence.load_active_messages/1`.
        state = seed_preloaded_messages(state, Map.get(attrs, :preloaded_messages, []))

        Init.persist_initial_system_message(state)

        Logger.info(
          "Agent started: #{state.name} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.mode}, tools: #{length(state.tools)}, client: #{inspect(state.client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source})"
        )

        {:ok, state}

      {:error, reason} ->
        cleanup_tmp(name)
        {:stop, reason}
    end
  end

  defp seed_preloaded_messages(state, []), do: state

  defp seed_preloaded_messages(state, preloaded) do
    seed_with_system_if_needed(state, preloaded)
  end

  # When the in-memory system message is already at position 0
  # of the preloaded list, use the list as-is.
  defp seed_with_system_if_needed(state, preloaded) do
    has_system? = Enum.any?(preloaded, &match?({:system, _}, &1))

    if has_system? do
      do_seed(state, preloaded)
    else
      prepend_system(state, preloaded)
    end
  end

  defp do_seed(state, preloaded) do
    highest_index =
      preloaded
      |> Enum.map(fn {_role, %{index: idx}} -> idx end)
      |> Enum.max(fn -> -1 end)

    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: preloaded,
            next_message_index: highest_index + 1
        }
    }
  end

  # Defensive prepend: pre-existing rows may have messages
  # but no persisted system row. Shift the preloaded list
  # up by one and seed the in-memory system message at
  # position 0 so the system prompt survives BEAM restart.
  defp prepend_system(state, preloaded) do
    [system | _] = state.chat_state.messages

    shifted =
      Enum.map(preloaded, fn {role, %{index: idx} = msg} ->
        {role, %{msg | index: idx + 1}}
      end)

    do_seed(state, [system | shifted])
  end

  @impl true
  def terminate(_reason, state) do
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

  @impl true
  def handle_call(:get_public_info, _from, state) do
    # Use the cached Vocation struct from state — no DB work in
    # the handler. The struct was loaded by the calling process
    # (test helper or production wrapper) and passed into init/1
    # via `:vocation` in attrs.
    vocation = state.vocation

    public_info = %{
      name: state.name,
      model: state.model,
      message_count: length(state.chat_state.messages),
      status: state.chat_state.status,
      vocation_id: state.vocation_id,
      tmp_path: state.tmp_path,
      partial: state.chat_state.streaming_acc,
      modes: Vocations.list_modes(vocation),
      default_mode: Vocations.default_mode(vocation),
      current_mode: state.mode,
      context_limit: state.llm_metrics.context_limit,
      context_limit_source: state.llm_metrics.context_limit_source,
      usage: state.llm_metrics.usage_totals
    }

    {:reply, public_info, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.chat_state.messages, state}
  end

  @impl true
  # Internal: returns `{messages, cancelled}` so the ChatTurn
  # can short-circuit on user-initiated stops without waiting
  # for the next `:stop_chat` message to be processed. The
  # chat turn checks `cancelled` after every iteration; when
  # true, it finalizes the partial assistant message (via
  # the agent's `chat_stopped` handler) and stops.
  def handle_call(:get_messages_with_cancelled, _from, state) do
    {:reply, {state.chat_state.messages, state.chat_state.cancelled}, state}
  end

  @impl true
  def handle_call(:get_next_index, _from, state) do
    {:reply, state.chat_state.next_message_index, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.chat_state.history || [], state}
  end

  # Test-only introspection: returns the assembled system prompt
  # (the content of the `{:system, _}` message at position 0 of
  # `state.chat_state.messages`). Not part of the public API; used
  # by the system-prompt composition tests in
  # `agent_system_prompt_composition_test.exs` and
  # `agent_agents_md_test.exs`.
  @impl true
  def handle_call(:get_system_prompt, _from, state) do
    {:reply, system_prompt_from_messages(state.chat_state.messages), state}
  end

  @impl true
  def handle_call(:get_chat_turn_pid, _from, state) do
    {:reply, state.chat_state.chat_turn_pid, state}
  end

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
    {stamped, state} = __append_message__(state, message)
    {:reply, stamped, state}
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

  defp system_prompt_from_messages([{:system, %{parts: parts}} | _]) when is_list(parts) do
    parts
    |> Enum.filter(&match?(%Nest.Messages.Part.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp system_prompt_from_messages(_), do: nil

  # Move the agent's current `messages` to `history` (with a
  # compaction marker), then replace `messages` with the new
  # compacted state. The marker is a `{:compaction, _}` tuple
  # that lives in `history` only — it never reaches the LLM.
  #
  # Implementation lives in `CompactionLifecycle`; this is a
  # thin forwarder so the GenServer module stays small.
  defdelegate __archive_and_compact__(state, new_messages), to: CompactionLifecycle, as: :apply

  @impl true
  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end

  # Private functions

  # Create a per-agent tmp directory for sandbox use
  # Pattern: /tmp/nest-{BEAM_pid}/agent-{agent_id}
  def __create_tmp_space__(agent_id) do
    tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"
    File.mkdir_p!(tmp_path)
    Logger.info("Created tmp space for agent #{agent_id}: #{tmp_path}")
    tmp_path
  end

  # Clean up the per-agent tmp directory and parent if empty
  defp cleanup_tmp(agent_id) do
    tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"
    File.rm_rf(tmp_path)
    Logger.info("Cleaned up tmp space for agent #{agent_id}: #{tmp_path}")

    # Try to clean up parent directory if empty
    parent_path = Path.dirname(tmp_path)

    case File.ls(parent_path) do
      {:ok, []} ->
        File.rmdir(parent_path)
        Logger.info("Cleaned up empty parent directory: #{parent_path}")

      _ ->
        :ok
    end
  end

  @doc false
  # Public-for-Handlers: the message-construction logic in
  # `Nest.Agents.Agent.Handlers` needs to read the queued
  # api_logs for a given message_index when assembling the
  # assistant/tool response message. The canonical impl lives
  # here; the `__` prefix marks it as internal.
  def __pending_api_logs__(state, message_index) do
    Map.get(state.chat_state.pending_api_logs, message_index, [])
  end

  @doc false
  # Public-for-Handlers: clear the queued api_logs for a
  # message_index after the message has been built. Returns
  # the new state so callers can chain updates.
  def __clear_pending_api_logs__(state, message_index) do
    %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs: Map.delete(state.chat_state.pending_api_logs, message_index)
        }
    }
  end
end
