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

  alias Nest.Agents.Registry
  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.LLM.Client
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Message
  alias Nest.Messages.Streaming
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User
  alias Nest.Tokens.BudgetPlanner
  alias Nest.Tokens.Compactor
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.PreFlight
  alias Nest.Tools
  alias Nest.Vocations

  defstruct [
    :id,
    :model,
    :client_config,
    :vocation_id,
    :system_prompt,
    :workspace_path,
    :tmp_path,
    :tools,
    :context_limit,
    :context_limit_source,
    :usage_totals,
    mode: "chat",
    messages: [],
    history: [],
    next_message_index: 0,
    streaming_acc: nil,
    status: :idle,
    active_message_index: 0,
    api_log_sequences: %{},
    pending_api_logs: %{}
  ]

  # Read-only context threaded through a single LLM call chain.
  # `RunState` carries the bits that change between iterations
  # (api_log_sequences, max_iterations, message_index).
  defmodule RunContext do
    @moduledoc false
    defstruct client_config: nil,
              tools: [],
              tool_choice: :auto,
              system_prompt: nil,
              messages: [],
              agent_pid: nil,
              agent_id: nil,
              caps: nil,
              context_limit: nil,
              context_limit_source: nil
  end

  defmodule RunState do
    @moduledoc false
    defstruct message_index: 0,
              active_message_index: 0,
              api_log_sequences: %{},
              max_iterations: nil
  end

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          client_config: ClientConfig.t(),
          vocation_id: integer() | nil,
          system_prompt: String.t() | nil,
          workspace_path: String.t() | nil,
          tmp_path: String.t() | nil,
          tools: [Nest.LLM.Tool.t()],
          context_limit: pos_integer() | nil,
          context_limit_source: Discover.source() | nil,
          usage_totals: RunResponse.usage() | nil,
          mode: String.t(),
          messages: [Message.t()],
          next_message_index: non_neg_integer(),
          streaming_acc: Streaming.AssistantAccumulator.t() | nil,
          status: :idle | :streaming | :executing_tools,
          active_message_index: non_neg_integer(),
          api_log_sequences: %{non_neg_integer() => non_neg_integer()}
        }

  @type message ::
          {:system, System.t()}
          | {:user, User.t()}
          | {:assistant, Assistant.t()}
          | {:tool, Tool.t()}

  # Fallback used when neither config nor the async probe has produced
  # a value. 128k is a safe lower bound for modern chat models and
  # keeps the token-usage chip rendering before the probe completes.
  @default_context_limit 128_000

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
    vocation_id = Map.get(attrs, :vocation_id)
    workspace_path = Map.get(attrs, :workspace_path)

    # Fetch vocation if provided
    {system_prompt, mode, tool_names} = fetch_vocation_config(vocation_id, workspace_path)

    # Create per-agent tmp space
    tmp_path = create_tmp_space(id)

    # Get tools for the agent (with tmp_path for sandbox)
    tools = Tools.get_functions(tool_names, workspace_path, tmp_path)

    # Create client config from model config
    case create_client_config(model) do
      {:ok, client_config} ->
        # Resolve the configured context limit from DotConfig; if absent,
        # default to 128k and let the async probe (spawned below)
        # refine the value once the provider's /models endpoint has
        # been queried. The synchronous Discover call would block
        # init/1 for up to 3s on slow providers, so we keep the
        # initial value cheap and update it via handle_info.
        configured_limit = configured_context_limit(model[:name] || model["name"])

        {context_limit, context_limit_source} =
          if configured_limit do
            {configured_limit, :config}
          else
            {@default_context_limit, :default}
          end

        # Build initial messages with system prompt if present
        {initial_messages, next_index} =
          if system_prompt do
            system_message =
              {:system,
               %System{
                 index: 0,
                 content: system_prompt,
                 timestamp: DateTime.utc_now(),
                 api_logs: []
               }}

            {[system_message], 1}
          else
            {[], 0}
          end

        state = %__MODULE__{
          id: id,
          model: model,
          client_config: client_config,
          vocation_id: vocation_id,
          system_prompt: system_prompt,
          workspace_path: workspace_path,
          tmp_path: tmp_path,
          tools: tools,
          context_limit: context_limit,
          context_limit_source: context_limit_source,
          usage_totals: empty_usage_totals(),
          mode: mode,
          messages: initial_messages,
          next_message_index: next_index,
          streaming_acc: nil,
          status: :idle,
          active_message_index: 0
        }

        # Broadcast system message if present
        if system_prompt do
          broadcast_message(id, List.first(initial_messages))
        end

        # If the user did not configure a context limit, kick off a probe
        # against the provider's /models endpoint. The result is delivered
        # back via `handle_info({:discovered_context_limit, ...}, state)`
        # and broadcast on the next `chat:status` push.
        if is_nil(configured_limit) do
          spawn_context_limit_probe(client_config, self())
        end

        Logger.info(
          "Agent started: #{id} with vocation_id: #{inspect(vocation_id)}, mode: #{mode}, tools: #{length(tools)}, client: #{inspect(client_config.client)}, context_limit: #{inspect(context_limit)} (#{context_limit_source})"
        )

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
    handle_chat(content, nil, state)
  end

  @impl true
  def handle_cast({:chat, content, mode}, state) do
    handle_chat(content, mode, state)
  end

  defp handle_chat(content, requested_mode, state) do
    # Resolve mode: explicit > agent's current mode > "chat"
    mode = requested_mode || state.mode
    # Validate mode against the vocation; fall back to default if invalid.
    {effective_mode, _caps} = resolve_mode_and_caps(mode, state.vocation_id)

    # Add user message to history with index
    user_message =
      {:user,
       %User{
         index: state.next_message_index,
         timestamp: DateTime.utc_now(),
         content: content,
         metadata: %{"mode" => effective_mode},
         api_logs: get_pending_api_logs(state, state.next_message_index)
       }}

    # The LLM sees the mode prefixed into the user content; the original
    # content (without the prefix) is what gets persisted and broadcast.
    llm_content = "[mode: #{effective_mode}]\n#{content}"

    # Build the LLM message with the prefixed content; the persisted
    # user message keeps the raw content + metadata.mode.
    persisted_user = user_message
    llm_user_message = {:user, %{elem(user_message, 1) | content: llm_content}}

    messages = state.messages ++ [persisted_user]
    messages_for_llm = state.messages ++ [llm_user_message]

    # Broadcast user message to all subscribers
    broadcast_message(state.id, user_message)

    # Update status to streaming
    state = %{
      state
      | messages: messages,
        next_message_index: state.next_message_index + 1,
        status: :streaming,
        active_message_index: state.next_message_index,
        pending_api_logs:
          clear_pending_api_logs(state, state.next_message_index).pending_api_logs,
        streaming_acc: Streaming.new(state.next_message_index + 1)
    }

    broadcast_status(state.id, :streaming)

    # Pre-flight: does the next LLM call fit? If not, the
    # Compactor runs first (in a Task); the chat task spawns
    # after compaction completes.
    state = maybe_compact_then_chat(state, messages_for_llm, content, mode)

    {:noreply, state}
  end

  # Pre-flight: would the LLM call we'd make next fit in the
  # context window? If not, spawn a compaction task first. The
  # task sends `{:compaction_done, new_messages, continuation}`
  # back; we then spawn the original chat task with the new
  # messages.
  defp maybe_compact_then_chat(state, messages_for_llm, content, mode) do
    # Plan §"In-progress state": compaction is disallowed while
    # streaming. The pre-flight will re-run on the next call
    # (which is the next chat turn, since the in-progress
    # stream is finalizing).
    if streaming_active?(state.streaming_acc) do
      spawn_chat_task(state, content, mode)
    else
      case preflight_decision(messages_for_llm, state) do
        :fits ->
          spawn_chat_task(state, content, mode)

        :no_limit_known ->
          spawn_chat_task(state, content, mode)

        :needs_compaction ->
          spawn_compaction_task(
            state,
            messages_for_llm,
            {:chat_continuation, {content, mode}}
          )
      end
    end
  end

  defp spawn_chat_task(state, content, mode) do
    agent_pid = self()
    {effective_mode, caps} = resolve_mode_and_caps(mode, state.vocation_id)

    # handle_chat has already added the user message to state.messages
    # and broadcast it. The last message in state.messages is our
    # user message; we just need to construct the LLM-bound version
    # with the mode prefix.
    user_message = List.last(state.messages)
    llm_user_message = llm_user_message(user_message, content, effective_mode)
    messages_for_llm = Enum.drop(state.messages, -1) ++ [llm_user_message]

    broadcast_message(state.id, user_message)

    # handle_chat (or the compaction continuation) has already
    # set state.streaming_acc to the correct index. Don't
    # overwrite it here — that would shift the assistant's index
    # by one.
    state = %{state | status: :streaming}
    broadcast_status(state.id, :streaming)

    ctx = %RunContext{
      client_config: state.client_config,
      tools: state.tools,
      system_prompt: state.system_prompt,
      messages: messages_for_llm,
      agent_pid: agent_pid,
      agent_id: state.id,
      caps: caps,
      context_limit: state.context_limit,
      context_limit_source: state.context_limit_source
    }

    init_state = %RunState{
      message_index: state.streaming_acc.index,
      active_message_index: state.active_message_index,
      api_log_sequences: state.api_log_sequences,
      max_iterations: configured_max_tool_iterations()
    }

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      %RunState{api_log_sequences: updated_sequences} =
        run_chain_with_callbacks(ctx, init_state)

      send(agent_pid, {:api_log_sequences_updated, updated_sequences})
    end)

    state
  end

  # Build a fresh user message struct. Mirrors the user-message
  # construction in handle_chat/3 so callers (the compaction
  # continuation flow) build the same shape.
  defp build_user_message(state, content, effective_mode) do
    {:user,
     %User{
       index: state.next_message_index,
       timestamp: DateTime.utc_now(),
       content: content,
       metadata: %{"mode" => effective_mode},
       api_logs: get_pending_api_logs(state, state.next_message_index)
     }}
  end

  defp llm_user_message(user_message, content, effective_mode) do
    llm_content = "[mode: #{effective_mode}]\n#{content}"
    {:user, %{elem(user_message, 1) | content: llm_content}}
  end

  defp preflight_decision(messages_for_llm, state) do
    PreFlight.check_messages(messages_for_llm, state.context_limit, 8_192)
  end

  # Per the plan, compaction is disallowed while streaming. We treat
  # "actively streaming" as `streaming_acc` having any accumulated
  # text or thinking content. A freshly-initialized accumulator (no
  # deltas yet) is NOT considered active — the pre-flight may still
  # compact in that brief window before the LLM's first token.
  defp streaming_active?(%Streaming.AssistantAccumulator{} = acc) do
    acc.text_buffer != "" or acc.thinking_buffer != ""
  end

  defp streaming_active?(_), do: false

  # Spawns a Task that runs the two-pass Compactor on the
  # current messages, then sends `{:compaction_done, new_messages,
  # continuation}` back. The continuation is whatever was queued
  # to happen after compaction (e.g. the next chat turn).
  defp spawn_compaction_task(state, messages_to_compact, continuation) do
    agent_pid = self()
    context_limit = state.context_limit
    client_config = state.client_config

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      result =
        try do
          llm_call = build_summarization_llm_call(client_config, agent_pid)

          {:ok, Compactor.compact(messages_to_compact, context_limit, llm_call)}
        catch
          kind, reason ->
            Logger.warning(
              "Compaction failed: #{inspect(kind)} #{inspect(reason)}. Proceeding with original messages."
            )

            {:error, {kind, reason}}
        end

      case result do
        {:ok, new_messages} ->
          send(agent_pid, {:compaction_done, new_messages, continuation})

        {:error, reason} ->
          send_compaction_failure(agent_pid, messages_to_compact, continuation, reason)
      end
    end)
  end

  # For chat and compact_context continuations, the GenServer's
  # :compaction_done handler treats the input as-is and broadcasts
  # a success log line. For preflight, the task is blocked on a
  # receive and needs an explicit failure message so it can fall
  # back to its existing snapshot.
  defp send_compaction_failure(
         agent_pid,
         _messages_to_compact,
         {:preflight_continuation, task_pid},
         reason
       ) do
    send(agent_pid, {:compaction_failed_for_preflight, task_pid, reason})
  end

  defp send_compaction_failure(agent_pid, messages_to_compact, continuation, _reason) do
    send(agent_pid, {:compaction_done, messages_to_compact, continuation})
  end

  # The LLM call the compactor uses. Wraps the chat client so the
  # summarization LLM request is routed through the same provider
  # the agent is using (KV cache prefix reuse, etc.).
  #
  # Deltas are sent to `compaction_pid` (the compactor task), not
  # broadcast — we don't want summarization progress to leak into
  # the chat PubSub topic. The compactor task ignores them.
  @summarization_prompt """
  You are a conversation summarizer.

  Produce a concise prose summary preserving:
    - The user's current goal
    - Key facts established
    - Decisions made
    - Any unresolved TODOs

  Drop redundant tool outputs and resolved sub-tasks. Be brief.
  """

  defp build_summarization_llm_call(%ClientConfig{} = client_config, compaction_pid) do
    fn messages ->
      request = %RunRequest{
        messages: reject_system_messages(messages),
        tools: nil,
        tool_choice: :none,
        model: client_config.model,
        system_prompt: @summarization_prompt,
        stream: true,
        metadata: %{}
      }

      opts = [
        base_url: client_config.base_url,
        api_key: client_config.api_key,
        receive_timeout: client_config.receive_timeout
      ]

      case client_config.client.run(request, opts) do
        {:ok, stream} ->
          text = consume_quietly(stream, compaction_pid)
          text || ""

        {:error, _reason} ->
          ""
      end
    end
  end

  # Consume a streaming response without broadcasting. The
  # `compaction_pid` receives delta messages (so the task can
  # observe progress if it wants), but no PubSub broadcast.
  defp consume_quietly(stream, compaction_pid) do
    acc = Client.new_accumulator()

    {_, response, _error, _} =
      Enum.reduce(
        stream,
        {acc, nil, nil, %{chars: 0, thinking_chars: 0}},
        fn
          {:text, text}, {acc, _response, error, sent} ->
            send(compaction_pid, {:delta_received, text, :text})
            {Client.accumulate(acc, {:text, text}), nil, error, sent}

          {:thinking, text}, {acc, response, error, sent} ->
            send(compaction_pid, {:delta_received, text, :thinking})
            {Client.accumulate(acc, {:thinking, text}), response, error, sent}

          {:tool_call_start, event}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:tool_call_start, event}), response, error, sent}

          {:tool_call_delta, event}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:tool_call_delta, event}), response, error, sent}

          {:thinking_signature, sig}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:thinking_signature, sig}), response, error, sent}

          {:usage, usage}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:usage, usage}), response, error, sent}

          {:finish_reason, _reason}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:finish_reason, nil}), response, error, sent}

          {:refusal, text}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:refusal, text}), response, error, sent}

          {:done, %{response: r}}, {acc, _response, error, sent} ->
            {acc, r, error, sent}

          {:error, reason}, {acc, response, _error, sent} ->
            {acc, response, reason, sent}

          other, {acc, response, error, sent} ->
            {Client.accumulate(acc, other), response, error, sent}
        end
      )

    case response do
      %RunResponse{text: text} -> text
      _ -> nil
    end
  end

  defp assign_indices(messages, start_index) do
    {messages, _} =
      Enum.map_reduce(messages, start_index, fn msg, idx ->
        {assign_index(msg, idx), idx + 1}
      end)

    messages
  end

  defp assign_index({role, %_{} = struct}, idx) do
    {role, %{struct | index: idx}}
  end

  defp assign_index(other, _idx), do: other

  # Resolves the effective mode and capability map for a chat message.
  #
  # If `mode` is in the vocation's `modes` map, use it as-is.
  # Otherwise fall back to the vocation's default mode (or "chat" if
  # the vocation has no modes). This matches the LLM-visible
  # `[mode: X]` prefix: we always emit a valid mode to the LLM.
  defp resolve_mode_and_caps(mode, vocation_id) do
    case if(vocation_id, do: Vocations.get_vocation(vocation_id), else: nil) do
      nil ->
        # No vocation: only "chat" is valid.
        if mode == "chat" do
          {"chat", Nest.Sandbox.default_caps()}
        else
          {"chat", Nest.Sandbox.default_caps()}
        end

      vocation ->
        modes = Vocations.list_modes(vocation)

        if mode in modes do
          {mode, elem(Vocations.get_caps(vocation, mode), 1)}
        else
          default = Vocations.default_mode(vocation)
          {default, elem(Vocations.get_caps(vocation, default), 1)}
        end
    end
  end

  @impl true
  def handle_call(:get_public_info, _from, state) do
    vocation =
      if state.vocation_id, do: Vocations.get_vocation(state.vocation_id), else: nil

    public_info = %{
      id: state.id,
      model: state.model,
      message_count: length(state.messages),
      status: state.status,
      vocation_id: state.vocation_id,
      tmp_path: state.tmp_path,
      partial: state.streaming_acc,
      modes: Vocations.list_modes(vocation),
      default_mode: Vocations.default_mode(vocation),
      current_mode: state.mode,
      context_limit: state.context_limit,
      context_limit_source: state.context_limit_source,
      usage: state.usage_totals
    }

    {:reply, public_info, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.history || [], state}
  end

  # Test-only introspection: returns the assembled system prompt. Not
  # part of the public API; used by the system_prompt composition
  # tests in agent_test.exs.
  @impl true
  def handle_call(:get_system_prompt, _from, state) do
    {:reply, state.system_prompt, state}
  end

  # Move the agent's current `messages` to `history` (with a
  # compaction marker), then replace `messages` with the new
  # compacted state. The marker is a `{:compaction, _}` tuple
  # that lives in `history` only — it never reaches the LLM.
  #
  # Indices are reassigned so the sequence stays monotonic and
  # the LLM never sees a gap.
  defp archive_and_compact(state, new_messages) do
    archived_count = length(state.messages || [])
    marker_index = state.next_message_index

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
    assigned_new = assign_indices(new_messages, new_start)

    state = %{
      state
      | messages: assigned_new,
        history: (state.history || []) ++ (state.messages || []) ++ [marker]
    }

    broadcast_compaction(state.id, marker, state.history)

    state
  end

  @impl true
  def handle_info({:delta_received, delta_content, part_type}, state) do
    # Accumulate delta using Streaming module based on content type
    acc = state.streaming_acc

    new_acc =
      case part_type do
        :text ->
          Streaming.append_text(acc, delta_content)

        :thinking ->
          Streaming.append_thinking(acc, delta_content)

        _ ->
          # For unsupported types, append as text for now
          Streaming.append_text(acc, delta_content)
      end

    {:noreply, %{state | streaming_acc: new_acc}}
  end

  @impl true
  def handle_info({:thinking_signature_received, signature}, state) do
    # Anthropic's extended thinking emits a signature alongside the
    # thinking content. Stash it on the streaming accumulator so it
    # round-trips into the persisted assistant message's metadata.
    new_acc = %{state.streaming_acc | thinking_signature: signature}
    {:noreply, %{state | streaming_acc: new_acc}}
  end

  @impl true
  def handle_info({:llm_error, error_msg}, state) do
    # Finalize error message
    error_message =
      {:assistant,
       %Assistant{
         index: state.streaming_acc.index,
         timestamp: DateTime.utc_now(),
         content: error_msg,
         thinking: nil,
         tool_calls: nil,
         api_logs: get_pending_api_logs(state, state.streaming_acc.index)
       }}

    messages = state.messages ++ [error_message]

    # Broadcast error message to all subscribers via PubSub
    broadcast_message(state.id, error_message)

    state = %{
      state
      | messages: messages,
        streaming_acc: nil,
        next_message_index: state.next_message_index + 1,
        active_message_index: state.streaming_acc.index,
        pending_api_logs:
          clear_pending_api_logs(state, state.streaming_acc.index).pending_api_logs,
        status: :idle
    }

    broadcast_status(state.id, :idle)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tool_calls_received, {:assistant, %Assistant{} = tool_call_message}}, state) do
    # Apply any pending api_logs to the tool call message
    index = tool_call_message.index
    pending_logs = get_pending_api_logs(state, index)

    tool_call_message =
      if pending_logs != [] do
        {:assistant,
         %{tool_call_message | api_logs: (tool_call_message.api_logs || []) ++ pending_logs}}
      else
        {:assistant, tool_call_message}
      end

    # Add tool call message to history
    messages = state.messages ++ [tool_call_message]

    # Broadcast tool call message
    broadcast_message(state.id, tool_call_message)

    state = %{
      state
      | messages: messages,
        next_message_index: state.next_message_index + 1,
        pending_api_logs: clear_pending_api_logs(state, index).pending_api_logs,
        status: :executing_tools
    }

    broadcast_status(state.id, :executing_tools)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tool_results_received, {:tool, %Tool{} = tool_result_message}}, state) do
    # Apply any pending api_logs to the tool result message
    index = tool_result_message.index
    pending_logs = get_pending_api_logs(state, index)

    tool_result_message =
      if pending_logs != [] do
        {:tool,
         %{tool_result_message | api_logs: (tool_result_message.api_logs || []) ++ pending_logs}}
      else
        {:tool, tool_result_message}
      end

    # Add tool result message to history
    messages = state.messages ++ [tool_result_message]

    # Broadcast tool result message
    broadcast_message(state.id, tool_result_message)

    state = %{
      state
      | messages: messages,
        next_message_index: state.next_message_index + 1,
        pending_api_logs: clear_pending_api_logs(state, index).pending_api_logs,
        status: :streaming,
        streaming_acc: Streaming.new(state.next_message_index + 1)
    }

    broadcast_status(state.id, :streaming)

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_response_with_thinking, _response, thinking}, state) do
    # Finalize assistant message with thinking using Streaming.finalize
    assistant = Streaming.finalize(state.streaming_acc)

    final_message =
      {:assistant,
       %Assistant{
         index: assistant.index,
         timestamp: DateTime.utc_now(),
         content: assistant.content,
         thinking: thinking,
         # Anthropic's extended-thinking signature, echoed back on
         # subsequent turns. The AnthropicClient reads this field
         # directly when rebuilding the assistant content block
         # array for the next request.
         thinking_signature: state.streaming_acc.thinking_signature,
         tool_calls: assistant.tool_calls,
         api_logs: get_pending_api_logs(state, state.streaming_acc.index)
       }}

    messages = state.messages ++ [final_message]

    # Broadcast completion to all subscribers via PubSub
    broadcast_message(state.id, final_message)

    state = %{
      state
      | messages: messages,
        streaming_acc: nil,
        next_message_index: state.next_message_index + 1,
        active_message_index: state.streaming_acc.index,
        pending_api_logs:
          clear_pending_api_logs(state, state.streaming_acc.index).pending_api_logs,
        status: :idle
    }

    broadcast_status(state.id, :idle)

    {:noreply, state}
  end

  @impl true
  def handle_info({:api_log, message_index, api_log}, state) do
    # Check if message exists
    message =
      Enum.find(state.messages, fn
        {:user, %{index: idx}} -> idx == message_index
        {:assistant, %{index: idx}} -> idx == message_index
        {:tool, %{index: idx}} -> idx == message_index
        {:system, %{index: idx}} -> idx == message_index
      end)

    if message do
      handle_api_log_for_existing_message(state, message_index, api_log)
    else
      handle_api_log_for_pending_message(state, message_index, api_log)
    end
  end

  @impl true
  def handle_info({:api_log_sequences_updated, updated_sequences}, state) do
    {:noreply, %{state | api_log_sequences: updated_sequences}}
  end

  @impl true
  def handle_info({:discovered_context_limit, source, limit}, state) do
    # Update state with the discovered limit and broadcast a fresh
    # chat:status so the frontend can swap the chip's denominator from
    # the default to the real value.
    state = %{state | context_limit: limit, context_limit_source: source}
    broadcast_status(state.id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_usage, usage}, state) do
    # Merge per-call usage into the running totals and broadcast a
    # fresh `chat:status` so the chip can update mid-stream.
    # `last_input` is overwritten (not summed): each LLM call's
    # `prompt_tokens` is the size of the full context sent for that
    # call, so the *most recent* value is the current context size.
    # `total_output` and `total_reasoning` are cumulative across the
    # session.
    state = %{state | usage_totals: merge_usage_totals(state.usage_totals, usage)}
    broadcast_status(state.id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    # Ignore normal exits from linked processes
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    # When trap_exit is enabled, EXIT signals are delivered as messages.
    # Stop the process for abnormal termination so terminate/2 is called.
    {:stop, reason, state}
  end

  @impl true
  def handle_info({:compaction_done, new_messages, continuation}, state) do
    Logger.info(
      "Compaction complete: agent=#{state.id} from=#{length(state.messages)} to=#{length(new_messages)}"
    )

    # Archive the previous messages to history with a marker,
    # then replace state.messages with the compacted state.
    state = archive_and_compact(state, new_messages)

    case continuation do
      {:chat_continuation, {content, mode}} ->
        # The compacted state replaced state.messages; we need to
        # add the user's NEW message to history before the chat
        # task runs (mirroring handle_chat/3's logic).
        {effective_mode, _} = resolve_mode_and_caps(mode, state.vocation_id)

        user_message = build_user_message(state, content, effective_mode)
        broadcast_message(state.id, user_message)

        state = %{
          state
          | messages: state.messages ++ [user_message],
            next_message_index: state.next_message_index + 1,
            status: :streaming,
            active_message_index: state.next_message_index,
            pending_api_logs:
              clear_pending_api_logs(state, state.next_message_index).pending_api_logs,
            streaming_acc: Streaming.new(state.next_message_index + 1)
        }

        broadcast_status(state.id, :streaming)
        state = spawn_chat_task(state, content, mode)
        {:noreply, state}

      {:preflight_continuation, task_pid} ->
        # The chat task that requested this pre-flight was sitting
        # in a `receive` waiting for the result. Send it the new
        # compacted message list so it can resume the LLM call.
        send(task_pid, {:preflight_result, :compacted, new_messages})
        {:noreply, state}

      {:compact_context_continuation, task_pid} ->
        # The chat task invoked the `compact_context` tool and is
        # blocked on a receive for the result. Send it the new
        # messages so it can construct the tool result string.
        send(task_pid, {:compact_context_done, new_messages})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:compact_context_from_task, task_pid, _focus}, state) do
    # The chat task is mid-flow and asked for explicit
    # compaction. Spawn the compactor and send the result back
    # to the task when done. The task will unblock its receive
    # and use the result.
    spawn_compaction_task(
      state,
      state.messages || [],
      {:compact_context_continuation, task_pid}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:compact_context_done, task_pid, new_messages}, state) do
    # Forward to a special handle_info that doesn't also run
    # the chat continuation. We mutate state directly here
    # and send the result back to the task.
    Logger.info(
      "compact_context tool: agent=#{state.id} from=#{length(state.messages)} to=#{length(new_messages)}"
    )

    state = archive_and_compact(state, new_messages)
    send(task_pid, {:compact_context_done, new_messages})
    {:noreply, state}
  end

  @impl true
  def handle_info({:preflight_request, task_pid, _messages_for_llm}, state) do
    # Called from the chat task right before each recursive LLM
    # call (after a tool iteration). Runs the pre-flight check
    # against the agent's *current* state.messages (the source
    # of truth, since the task's snapshot may be stale by now).
    # If compaction is needed, spawns a compactor and the task
    # waits for the result; otherwise replies `:proceed` and the
    # task uses its current snapshot unchanged.
    if streaming_active?(state.streaming_acc) do
      send(task_pid, {:preflight_result, :proceed, state.messages || []})
      {:noreply, state}
    else
      case preflight_decision(state.messages || [], state) do
        decision when decision in [:fits, :no_limit_known] ->
          send(task_pid, {:preflight_result, :proceed, state.messages || []})
          {:noreply, state}

        :needs_compaction ->
          spawn_compaction_task(
            state,
            state.messages || [],
            {:preflight_continuation, task_pid}
          )

          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({:compaction_failed_for_preflight, task_pid, _reason}, state) do
    # Compactor raised (LLM error, etc.). The chat task is
    # blocked waiting for a result; let it proceed with its
    # existing snapshot rather than deadlock the agent.
    send(task_pid, {:preflight_result, :proceed, state.messages || []})
    {:noreply, state}
  end

  @impl true
  def handle_info({:compact_context_failed, task_pid, reason}, state) do
    Logger.warning("compact_context tool failed: #{inspect(reason)}")
    send(task_pid, {:compact_context_failed, reason})
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Catch-all for unexpected messages
    {:noreply, state}
  end

  defp handle_api_log_for_existing_message(state, message_index, api_log) do
    messages =
      Enum.map(state.messages, fn
        {:user, %User{} = msg} when msg.index == message_index ->
          {:user, %{msg | api_logs: (msg.api_logs || []) ++ [api_log]}}

        {:assistant, %Assistant{} = msg} when msg.index == message_index ->
          {:assistant, %{msg | api_logs: (msg.api_logs || []) ++ [api_log]}}

        {:tool, %Tool{} = msg} when msg.index == message_index ->
          {:tool, %{msg | api_logs: (msg.api_logs || []) ++ [api_log]}}

        {:system, %System{} = msg} when msg.index == message_index ->
          {:system, %{msg | api_logs: (msg.api_logs || []) ++ [api_log]}}

        msg ->
          msg
      end)

    updated_message =
      Enum.find(messages, fn
        {:user, %{index: idx}} -> idx == message_index
        {:assistant, %{index: idx}} -> idx == message_index
        {:tool, %{index: idx}} -> idx == message_index
        {:system, %{index: idx}} -> idx == message_index
      end)

    broadcast_message(state.id, updated_message)

    {:noreply, %{state | messages: messages}}
  end

  defp handle_api_log_for_pending_message(state, message_index, api_log) do
    pending = Map.get(state.pending_api_logs, message_index, [])
    pending_api_logs = Map.put(state.pending_api_logs, message_index, pending ++ [api_log])

    {:noreply, %{state | pending_api_logs: pending_api_logs}}
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
  defp configured_context_limit(nil), do: nil

  defp configured_context_limit(model_name) when is_binary(model_name) do
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
  defp spawn_context_limit_probe(%ClientConfig{} = client_config, agent_pid) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      {source, limit} = Discover.context_limit(client_config)
      send(agent_pid, {:discovered_context_limit, source, limit})
    end)
  end

  defp fetch_vocation_config(nil, _workspace_path), do: {nil, "chat", []}

  defp fetch_vocation_config(vocation_id, workspace_path) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        {nil, "chat", []}

      vocation ->
        initial_mode = get_initial_mode(vocation.modes)
        tools = vocation.tools || []
        # Append the mode catalog so the LLM knows which modes the
        # user can pick. The LLM does not pick modes itself — the
        # user does, via the UI chip. Then append the workspace
        # path so the LLM knows where to read/write files.
        system_prompt =
          vocation.system_prompt <>
            Vocations.mode_catalog(vocation) <>
            workspace_section(workspace_path)

        {system_prompt, initial_mode, tools}
    end
  end

  # Renders a short workspace line that tells the LLM where the
  # agent's working directory lives. Only included when a workspace
  # was configured at agent creation.
  defp workspace_section(nil), do: ""

  defp workspace_section(path) do
    "\n\nWorkspace and tool working directory: #{path}\n"
  end

  defp get_initial_mode(nil), do: "chat"

  defp get_initial_mode(%{} = modes) when map_size(modes) > 0 do
    modes |> Map.keys() |> List.first()
  end

  defp get_initial_mode(_), do: "chat"

  # Create a per-agent tmp directory for sandbox use
  # Pattern: /tmp/nest-{BEAM_pid}/agent-{agent_id}
  defp create_tmp_space(agent_id) do
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

  defp run_chain_with_callbacks(%RunContext{} = ctx, %RunState{} = state) do
    run_with_new_client(ctx, state)
  end

  # New client path. Consumes the canonical event stream, drives the
  # accumulator via the GenServer's handle_info, and recursively
  # handles tool calls until the LLM returns a final response or
  # the iteration cap is hit.
  defp run_with_new_client(%RunContext{} = ctx, %RunState{max_iterations: 0} = state) do
    Logger.warning(
      "Agent #{ctx.agent_id} reached max tool iterations, making final call without tools"
    )

    broadcast_notification(ctx.agent_id, %{
      type: "max_iterations",
      message: "Max tool iterations reached"
    })

    # Make one final LLM call with tools disabled (both tools and tool_choice)
    # so the LLM sees the tool results and produces a text response
    final_ctx = %{ctx | tools: nil, tool_choice: :none}

    state = broadcast_request_log(final_ctx, state)
    {:ok, stream} = run_request(final_ctx)
    handle_new_stream(final_ctx, state, stream)
  end

  defp run_with_new_client(%RunContext{} = ctx, %RunState{} = state) do
    # Plan §"Compaction flow": pre-flight runs at the start of
    # every LLM call site. The chat task asks the GenServer to
    # re-check (state.messages may have grown via archived API
    # logs since the last call) and reply with either `:proceed`
    # (use the existing snapshot) or `:compacted` (use the new
    # compacted list).
    case run_preflight(ctx) do
      {:compacted, new_messages} ->
        run_with_new_client(%{ctx | messages: new_messages}, state)

      :proceed ->
        Logger.info("Agent #{ctx.agent_id} sending LLM request (message #{state.message_index})")
        state = broadcast_request_log(ctx, state)
        {:ok, stream} = run_request(ctx)
        handle_new_stream(ctx, state, stream)
    end
  end

  # Asks the GenServer to run a pre-flight check on its current
  # state.messages. Returns `:proceed` if the next LLM call fits
  # (or no limit is known / a stream is in progress) and
  # `{:compacted, new_messages}` if the compactor ran. The chat
  # task blocks here on a `receive`, mirroring the
  # `compact_context` tool's round-trip pattern.
  defp run_preflight(ctx) do
    send(ctx.agent_pid, {:preflight_request, self(), ctx.messages})

    receive do
      {:preflight_result, :proceed, _messages} ->
        :proceed

      {:preflight_result, :compacted, new_messages} ->
        {:compacted, new_messages}
    after
      30_000 ->
        Logger.warning("Pre-flight request timed out; proceeding with existing messages")
        :proceed
    end
  end

  defp broadcast_request_log(ctx, %RunState{} = state) do
    request = build_run_request(ctx)
    opts = build_run_opts(ctx)

    sequences =
      broadcast_new_request_log(
        ctx.client_config,
        request,
        opts,
        ctx.agent_pid,
        state.active_message_index,
        state.api_log_sequences
      )

    %{state | api_log_sequences: sequences}
  end

  defp build_run_request(ctx) do
    %RunRequest{
      # Strip leading `{:system, _}` tuples — the system prompt
      # is now carried in `system_prompt` so both providers
      # (Anthropic's top-level `system` field, OpenAI's leading
      # `system` message) can shape it without scanning the
      # messages array.
      messages: reject_system_messages(ctx.messages),
      tools: ctx.tools,
      tool_choice: ctx.tool_choice,
      model: ctx.client_config.model,
      system_prompt: ctx.system_prompt,
      metadata: %{}
    }
  end

  defp reject_system_messages(messages) do
    Enum.reject(messages, fn
      {:system, _} -> true
      _ -> false
    end)
  end

  defp build_run_opts(ctx) do
    [
      base_url: ctx.client_config.base_url,
      api_key: ctx.client_config.api_key,
      receive_timeout: ctx.client_config.receive_timeout,
      # Threaded through opts so a test's per-agent mock client (e.g.
      # `Nest.LLM.MockClient` in `lib/nest/llm/mock_client.ex`) can
      # find the queue scoped to this agent pid. The real
      # OpenAI/Anthropic clients ignore unknown keys.
      agent_pid: ctx.agent_pid
    ]
  end

  defp run_request(ctx) do
    ctx.client_config.client.run(build_run_request(ctx), build_run_opts(ctx))
  end

  defp handle_new_stream(ctx, state, stream) do
    {_acc, response, error, _sent} =
      consume_new_stream(stream, state.message_index, ctx.agent_id, ctx.agent_pid)

    if error do
      handle_failed_response(state, error, ctx)
    else
      handle_new_response(ctx, state, response)
    end
  end

  defp handle_new_response(ctx, state, response) do
    sequences =
      broadcast_new_response_log(
        ctx.agent_pid,
        state.message_index,
        state.api_log_sequences,
        response
      )

    state = %{state | api_log_sequences: sequences}

    # Forward usage to the GenServer so the running totals update
    # and the next chat:status push carries the fresh numbers.
    # `usage` is `nil` for clients that don't populate it; the merge
    # helper treats nil as a no-op.
    send(ctx.agent_pid, {:llm_usage, response.usage})

    if RunResponse.has_tool_calls?(response) do
      run_with_new_client_after_tool_calls(ctx, state, response)
    else
      send_final_assistant(ctx, state, response)
    end
  end

  defp send_final_assistant(ctx, state, response) do
    send(ctx.agent_pid, {:llm_response_with_thinking, response, response.thinking})
    # The terminal path returns the state so the caller's
    # `Task.Supervisor.start_child/2` body can destructure
    # `%RunState{api_log_sequences: _}`. `api_log_sequences`
    # returned by `run_with_new_client_after_tool_calls/3`
    # flows through unchanged; the final path threads it.
    state
  end

  defp run_with_new_client_after_tool_calls(ctx, state, response) do
    {tool_call_message, tool_result_message, updated_messages} =
      build_tool_pair(ctx, state, response)

    send(ctx.agent_pid, {:tool_calls_received, tool_call_message})
    send(ctx.agent_pid, {:tool_results_received, tool_result_message})

    next_state = %RunState{
      message_index: state.message_index + 2,
      active_message_index: state.message_index + 1,
      api_log_sequences: state.api_log_sequences,
      max_iterations: state.max_iterations - 1
    }

    run_with_new_client(%{ctx | messages: updated_messages}, next_state)
  end

  defp build_tool_pair(ctx, state, response) do
    tool_call_message =
      {:assistant,
       %Assistant{
         index: state.message_index,
         timestamp: DateTime.utc_now(),
         content: response.text,
         tool_calls: response.tool_calls,
         # Anthropic's extended-thinking signature, echoed back on
         # subsequent turns. The AnthropicClient reads this field
         # directly when rebuilding assistant content blocks for
         # the next request.
         thinking_signature: response.thinking_signature,
         api_logs: []
       }}

    # The BudgetPlanner runs each tool call through the budget loop
    # (fits / truncates / skips / cascade-skip). It preserves call
    # order in its output. We rebuild the ToolResult list from the
    # planner's output — the planner's strings already include
    # truncation notes and skip responses where appropriate.
    tool_results =
      run_tool_budget_loop(
        ctx,
        state,
        response.tool_calls || []
      )

    tool_result_message =
      {:tool,
       %Tool{
         index: state.message_index + 1,
         timestamp: DateTime.utc_now(),
         tool_results: tool_results,
         api_logs: []
       }}

    {tool_call_message, tool_result_message,
     ctx.messages ++ [tool_call_message, tool_result_message]}
  end

  # Runs the per-tool budget loop, returning a list of `ToolResult`
  # structs in the same order as the input `tool_calls`.
  #
  # The executor callback returns `{result_string, tool_default_max}`.
  # `BudgetPlanner` uses the default to enforce the per-tool cap; the
  # LLM can override it on a per-call basis via
  # `max_result_tokens` in the call's arguments (read directly by
  # the planner).
  defp run_tool_budget_loop(ctx, _state, tool_calls) do
    budget_remaining = compute_remaining_budget(ctx)

    executor = build_tool_executor(ctx)

    results =
      BudgetPlanner.execute(tool_calls, executor, budget_remaining, [])

    Enum.map(results, fn {tool_call, result_string} ->
      %ToolResult{
        tool_call_id: tool_call.id,
        name: tool_call_name(tool_call),
        content: ensure_non_empty_tool_result(result_string),
        arguments: tool_call_arguments(tool_call),
        is_error: skip_response?(result_string)
      }
    end)
  end

  defp build_tool_executor(ctx) do
    fn tool_call ->
      case tool_call_name(tool_call) do
        "compact_context" ->
          # The compact_context tool needs to mutate the agent's
          # state.messages. The chat task can't do that directly,
          # so it round-trips through the GenServer: send a
          # request, the GenServer runs the compactor, then sends
          # the result back. The chat task blocks on a receive
          # until the result arrives.
          result = request_compaction_from_task(ctx, tool_call)
          {result, 256}

        _ ->
          raw = LLMTools.execute_one(ctx.tools, tool_call, %{caps: ctx.caps})

          {content, default_max} = tool_result_for(raw, ctx, tool_call)
          {content, default_max || 8192}
      end
    end
  end

  defp tool_result_for({:ok, content}, ctx, tool_call) do
    {content, LLMTools.default_max_result_tokens(ctx.tools, tool_call_name(tool_call))}
  end

  defp tool_result_for({:error, reason}, ctx, tool_call) do
    {reason, LLMTools.default_max_result_tokens(ctx.tools, tool_call_name(tool_call))}
  end

  # Round-trip the compaction request through the GenServer. The
  # chat task sends a request, then blocks on a receive for the
  # result. The GenServer runs the compactor (in a Task) and
  # sends the new messages back. The chat task then constructs
  # a synthetic tool result for the LLM.
  defp request_compaction_from_task(ctx, tool_call) do
    agent_pid = ctx.agent_pid
    focus = get_focus_arg(tool_call)

    send(agent_pid, {:compact_context_from_task, self(), focus})

    receive do
      {:compact_context_done, new_messages} ->
        "Compacted #{state_messages_count(ctx)} messages into a summary. You now have ~#{estimate_new_working_space(new_messages, ctx.context_limit)} tokens of working space."

      {:compact_context_failed, reason} ->
        "Compaction failed: #{inspect(reason)}"
    after
      60_000 ->
        "Compaction timed out"
    end
  end

  defp get_focus_arg(tool_call) do
    case tool_call.arguments do
      %{"focus" => f} when is_binary(f) -> f
      _ -> nil
    end
  end

  # Helper for the synthetic tool result string. The "before"
  # count is whatever the chat task is using (we don't have
  # direct access here; just say "messages"). The "after" count
  # is the new length. The "working space" is the recent slice
  # after compaction.
  defp state_messages_count(ctx) do
    length(ctx.messages || [])
  end

  defp estimate_new_working_space(new_messages, context_limit) do
    case context_limit do
      nil ->
        "unknown"

      limit when is_integer(limit) ->
        # Roughly: context_limit minus the new messages size minus
        # the reserve. Just an estimate for the LLM's awareness.
        used = Estimator.estimate_messages(new_messages)
        max(0, limit - used - 8_192)
    end
  end

  # Conservative budget for the tool-result batch. The pre-flight
  # (step 5) will replace this rough estimate with the real one.
  # For now, we charge against the running history and the budget
  # is roughly `context_limit - reserve - estimated_used`. If we
  # don't know the limit, fall back to a large number so the
  # BudgetPlanner effectively passes everything through (degraded
  # behavior — better than over-aggressive truncation).
  defp compute_remaining_budget(ctx) do
    case ctx.context_limit do
      nil ->
        1_000_000

      limit when is_integer(limit) ->
        reserve = 8192
        used = Estimator.estimate_messages(ctx.messages || [])
        max(0, limit - reserve - used)
    end
  end

  defp tool_call_name(%{name: name}), do: name || "unknown"
  defp tool_call_name(_), do: "unknown"

  defp tool_call_arguments(%{arguments: args}) when is_map(args), do: args
  defp tool_call_arguments(_), do: %{}

  defp skip_response?(content) when is_binary(content) do
    String.starts_with?(content, "[skipped:")
  end

  defp skip_response?(_), do: false

  defp ensure_non_empty_tool_result(""), do: "[no output]"
  defp ensure_non_empty_tool_result(nil), do: "[no output]"
  defp ensure_non_empty_tool_result(s) when is_binary(s), do: s
  defp ensure_non_empty_tool_result(other), do: to_string(other)

  defp consume_new_stream(stream, message_index, agent_id, agent_pid) do
    {acc, response, error, sent} =
      Enum.reduce(
        stream,
        {Client.new_accumulator(), nil, nil, %{chars: 0, thinking_chars: 0}},
        fn
          {:text, text}, {acc, response, error, sent} ->
            broadcast_delta_text(agent_id, message_index, text, sent.chars)
            send(agent_pid, {:delta_received, text, :text})

            new_chars = sent.chars + String.length(text)
            {Client.accumulate(acc, {:text, text}), response, error, %{sent | chars: new_chars}}

          {:thinking, text}, {acc, response, error, sent} ->
            send(agent_pid, {:delta_received, text, :thinking})
            {Client.accumulate(acc, {:thinking, text}), response, error, sent}

          {:tool_call_start, event}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:tool_call_start, event}), response, error, sent}

          {:tool_call_delta, event}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:tool_call_delta, event}), response, error, sent}

          {:thinking_signature, sig}, {acc, response, error, sent} ->
            # Anthropic's extended thinking emits a signature that
            # must be echoed back on subsequent turns. Forward it
            # to the agent pid so it can be persisted in the
            # assistant message's metadata.
            send(agent_pid, {:thinking_signature_received, sig})
            {Client.accumulate(acc, {:thinking_signature, sig}), response, error, sent}

          {:usage, usage}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:usage, usage}), response, error, sent}

          {:finish_reason, reason}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:finish_reason, reason}), response, error, sent}

          {:refusal, text}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:refusal, text}), response, error, sent}

          {:done, %{response: r}}, {acc, _response, error, sent} ->
            {acc, r, error, sent}

          {:error, reason}, {acc, response, _error, sent} ->
            {acc, response, reason, sent}
        end
      )

    final_response = normalize_response(response, acc)
    # `sent` carries chars-sent counters used for delta broadcasting;
    # the running total is already in `acc`'s text buffer at this point.
    _ = sent
    {acc, final_response, error, sent}
  end

  # The accumulator is the source of truth for parsed tool calls.
  # The :done event's response.tool_calls (when set) carries whatever the
  # client decided to put there, which may be plain maps (mock) or
  # `Nest.LLM.Tool` structs. We replace it with the accumulator's
  # normalized `Nest.Messages.ToolCall` list so downstream consumers
  # can pattern-match on the struct. `usage` is propagated from the
  # accumulator too, since some clients (and the test mock) emit
  # `{:usage, _}` events without echoing the value back into the
  # `:done` response payload.
  defp normalize_response(nil, acc) do
    Client.finalize(acc, nil)
  end

  defp normalize_response(%RunResponse{} = response, acc) do
    finalized = Client.finalize(acc, response.model)

    %{
      response
      | tool_calls: finalized.tool_calls,
        text: response.text || finalized.text,
        thinking: response.thinking || finalized.thinking,
        thinking_signature: response.thinking_signature || finalized.thinking_signature,
        usage: response.usage || finalized.usage
    }
  end

  defp broadcast_delta_text(agent_id, message_index, content, chars_start) do
    chars_end = chars_start + String.length(content)

    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_delta,
       %{
         index: message_index,
         content: content,
         chars_start: chars_start,
         chars_end: chars_end,
         part_type: :text
       }}
    )
  end

  defp broadcast_new_request_log(
         client_config,
         request,
         opts,
         agent_pid,
         active_message_index,
         api_log_sequences
       ) do
    payload = client_config.client.format_request_payload(request, opts)
    {api_log_id, updated_sequences} = get_next_api_log_id(active_message_index, api_log_sequences)
    broadcast_api_log(agent_pid, active_message_index, api_log_id, payload)
    updated_sequences
  end

  defp broadcast_new_response_log(agent_pid, message_index, api_log_sequences, response) do
    payload = build_api_response_from_run(response)
    {api_log_id, updated_sequences} = get_next_api_log_id(message_index, api_log_sequences)
    broadcast_api_response(agent_pid, message_index, api_log_id, payload)
    updated_sequences
  end

  defp handle_failed_response(state, error, ctx) do
    error_msg = "Error: #{inspect(error)}"

    Logger.error("Agent #{ctx.agent_id} LLM request failed: #{error_msg}")

    # Broadcast error to all subscribers via PubSub
    broadcast_error(ctx.agent_id, state.message_index, error_msg)

    # Notify agent that streaming failed (similar to successful response)
    send(ctx.agent_pid, {:llm_error, error_msg})

    # Return the state so the caller's
    # `Task.Supervisor.start_child/2` body can destructure
    # `%RunState{api_log_sequences: _}`. Sequences are unchanged
    # on the failure path — no new request log was generated.
    state
  end

  # PubSub broadcast helpers

  defp broadcast_message(agent_id, message) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_message, message}
    )
  end

  defp broadcast_error(agent_id, message_index, error_msg) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_error,
       %{
         index: message_index,
         content: error_msg
       }}
    )
  end

  defp broadcast_status(agent_id, %__MODULE__{} = state) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_status, build_status_payload(state)}
    )
  end

  defp broadcast_status(agent_id, status) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_status, %{status: to_string(status)}}
    )
  end

  # Broadcasts a chat:compaction event after archive_and_compact.
  # The frontend uses this to update the local history list (so
  # the CompactionMarker component can render) and to clear the
  # message list back to the LLM's view of the world.
  defp broadcast_compaction(agent_id, {:compaction, marker}, history) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_compaction,
       %{
         marker: Compaction.to_json(marker),
         history: Enum.map(history || [], &Message.to_json/1)
       }}
    )
  end

  # Wire-format status payload. Always include the current context_limit
  # and source so the frontend can render the token usage chip without
  # waiting for a separate init / chat:status reply. `usage` carries
  # the running totals (prompt_tokens, completion_tokens, etc.) so the
  # chip numerator updates mid-stream.
  defp build_status_payload(%__MODULE__{} = state) do
    %{
      status: to_string(state.status),
      contextLimit: state.context_limit,
      contextLimitSource: state.context_limit_source,
      usage: state.usage_totals
    }
  end

  # Initial / reset state for `usage_totals`. Distinct from the
  # `nil` value the accumulator produces: the agent always has a
  # map, even before the first LLM call has returned.
  defp empty_usage_totals do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      reasoning_tokens: 0,
      last_output: 0
    }
  end

  # Combine a fresh usage payload into the running totals.
  #
  # The canonical usage map emitted by both clients uses
  # `:input_tokens` (the size of the full context for that call)
  # and `:output_tokens` (the tokens just generated). Providers
  # may also surface `:reasoning_tokens` (Anthropic, o1-style
  # OpenAI) and `:cache_read_input_tokens` / `:cache_creation_input_tokens`
  # (Anthropic).
  #
  # - `input_tokens` overwrites, not adds: it is the size of the
  #   full context for that call, so the most recent value is
  #   the current context size.
  # - `last_output` mirrors the same overwrite semantics for the
  #   assistant turn that just finished.
  # - `output_tokens`, `total_tokens`, `reasoning_tokens` are
  #   summed across the session.
  # - A `nil` `usage` is a no-op (callers that don't populate it
  #   shouldn't zero out the running totals).
  defp merge_usage_totals(current, nil), do: current

  defp merge_usage_totals(current, usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens)
    output = Map.get(usage, :output_tokens, 0)
    total = Map.get(usage, :total_tokens, 0)
    reasoning = Map.get(usage, :reasoning_tokens, 0)

    %{
      input_tokens: if(input != nil, do: input, else: current.input_tokens),
      output_tokens: current.output_tokens + output,
      total_tokens: current.total_tokens + total,
      reasoning_tokens: current.reasoning_tokens + reasoning,
      last_output: if(input != nil, do: output, else: current.last_output)
    }
  end

  defp broadcast_notification(agent_id, payload) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_notification, payload}
    )
  end

  defp broadcast_api_log(agent_pid, message_index, api_log_id, api_payload) do
    send(
      agent_pid,
      {:api_log, message_index,
       %{
         id: api_log_id,
         timestamp: DateTime.utc_now(),
         type: :request,
         payload: api_payload
       }}
    )
  end

  defp broadcast_api_response(agent_pid, message_index, api_log_id, api_response) do
    send(
      agent_pid,
      {:api_log, message_index,
       %{
         id: api_log_id,
         timestamp: DateTime.utc_now(),
         type: :response,
         payload: api_response
       }}
    )
  end

  defp get_next_api_log_id(message_index, sequences) do
    sequence = Map.get(sequences, message_index, 0)
    updated_sequences = Map.put(sequences, message_index, sequence + 1)
    id = :io_lib.format("~3..0B.~3..0B", [message_index, sequence]) |> IO.iodata_to_binary()
    {id, updated_sequences}
  end

  defp build_api_response_from_run(%RunResponse{} = response) do
    %{
      role: :assistant,
      content: response.text,
      tool_calls: response.tool_calls,
      tool_results: nil,
      stop_reason: response.stop_reason,
      usage: response.usage
    }
  end

  defp get_pending_api_logs(state, message_index) do
    Map.get(state.pending_api_logs, message_index, [])
  end

  defp clear_pending_api_logs(state, message_index) do
    %{state | pending_api_logs: Map.delete(state.pending_api_logs, message_index)}
  end
end
