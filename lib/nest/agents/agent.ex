defmodule Nest.Agents.Agent do
  @moduledoc """
  GenServer that manages an individual agent's state and chat.

  Each agent runs as an independent process with:
  - A unique readable ID (e.g., "clever-raven")
  - Message history with tool calling support
  - LLM client config for model communication
  - Streaming broadcast support for real-time responses via PubSub
  """

  use GenServer, restart: :temporary

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Registry
  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover
  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Vocations

  defstruct [
    :id,
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
          id: String.t(),
          model: map(),
          client_config: ClientConfig.t(),
          vocation_id: integer() | nil,
          vocation: Vocations.Vocation.t() | nil,
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

  # Fallback used when neither config nor the async probe has produced
  # a value lives in `Nest.Agents.Agent.Init`. 128k is a safe lower
  # bound for modern chat models and keeps the token-usage chip
  # rendering before the probe completes.

  # Client API

  @doc """
  Starts an agent process with the given attributes.

  Required keys:
  - `:id` - Unique readable agent ID
  - `:model` - Model configuration map with :name key

  The agent registers itself in the Registry under its ID.
  """
  @spec start_link(attrs :: map()) :: GenServer.on_start()
  def start_link(attrs) do
    id = Map.fetch!(attrs, :id)
    GenServer.start_link(__MODULE__, attrs, name: Registry.via_tuple(id))
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

    id = Map.fetch!(attrs, :id)
    model = Map.fetch!(attrs, :model)

    case create_client_config(model) do
      {:ok, client_config} ->
        state = Init.build_state(attrs, client_config)
        Init.run_post_init(state, client_config)
        {:ok, state}

      {:error, reason} ->
        cleanup_tmp(id)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Cleanup /tmp per design specification
    cleanup_tmp(state.id)

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
    vocation =
      if state.vocation_id, do: Vocations.get_vocation(state.vocation_id), else: nil

    public_info = %{
      id: state.id,
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
  @spec __append_message__(t(), {atom(), map()}) :: {term(), t()}
  def __append_message__(state, message) do
    index = state.chat_state.next_message_index
    stamped = put_message_index(message, index)

    messages = state.chat_state.messages ++ [stamped]

    state = %{
      state
      | chat_state: %{state.chat_state | messages: messages, next_message_index: index + 1}
    }

    Broadcasts.message(state.id, stamped)
    {stamped, state}
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

  defp system_prompt_from_messages([{:system, %{content: content}} | _]) when is_binary(content),
    do: content

  defp system_prompt_from_messages(_), do: nil

  # Move the agent's current `messages` to `history` (with a
  # compaction marker), then replace `messages` with the new
  # compacted state. The marker is a `{:compaction, _}` tuple
  # that lives in `history` only — it never reaches the LLM.
  #
  # Indices are reassigned so the sequence stays monotonic and
  # the LLM never sees a gap.
  def __archive_and_compact__(state, new_messages) do
    archived_count = length(state.chat_state.messages || [])
    marker_index = state.chat_state.next_message_index

    marker =
      {:compaction,
       %Nest.Messages.Compaction{
         index: marker_index,
         archived_count: archived_count,
         occurred_at: DateTime.utc_now(),
         metadata: nil
       }}

    # The new compacted state starts at marker_index + 1.
    new_start = marker_index + 1
    assigned_new = Compaction.assign_indices(new_messages, new_start)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: assigned_new,
            history:
              (state.chat_state.history || []) ++ (state.chat_state.messages || []) ++ [marker]
        }
    }

    Broadcasts.compaction(state.id, marker, state.chat_state.history)

    state
  end

  @impl true
  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end

  # Private functions

  defp create_client_config(model) do
    model_name = model[:name] || model["name"]

    if model_name do
      ChatModel.new(model: model_name)
    else
      {:error, :no_model_name}
    end
  end

  # Look up the user-configured `context-limit` for this model in
  # DotConfig. Returns `nil` when absent so the caller can decide
  # whether to fall through to the probe.
  @doc false
  def configured_context_limit(nil), do: nil

  def configured_context_limit(model_name) when is_binary(model_name) do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.get_model(config, model_name) do
          nil -> nil
          model -> model.context_limit
        end

      _ ->
        nil
    end
  end

  # Resolves the per-chat tool-call iteration cap. Reads the optional
  # top-level `max-tool-iterations` value from DotConfig; falls back
  # to `DotConfig.default_max_tool_iterations/0` (25) when unset.
  @doc false
  def configured_max_tool_iterations do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.max_tool_iterations(config) do
          nil -> DotConfig.default_max_tool_iterations()
          n -> n
        end

      _ ->
        DotConfig.default_max_tool_iterations()
    end
  end

  # Fire-and-forget probe against the provider's /models endpoint.
  # The result is delivered to the GenServer via `send/2` so init/1
  # can return immediately. Failures and unparseable bodies fall
  # through to the default inside `Discover.context_limit/1`, so
  # this task never raises into the GenServer mailbox.
  def __spawn_context_limit_probe__(%ClientConfig{} = client_config, agent_pid) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      {source, limit} = Discover.context_limit(client_config)
      send(agent_pid, {:discovered_context_limit, source, limit})
    end)
  end

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
