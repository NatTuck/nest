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
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.LLMRunner
  alias Nest.Agents.Registry
  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover
  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.Streaming
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Tokens.PreFlight
  alias Nest.Tools
  alias Nest.Vocations

  defstruct [
    :id,
    :model,
    :client_config,
    :vocation_id,
    :vocation,
    :system_prompt,
    :workspace_path,
    :tmp_path,
    :tools,
    :llm_metrics,
    mode: "chat",
    chat_state: %__MODULE__.ChatState{}
  ]

  # Read-only context threaded through a single LLM call chain
  # (`RunContext`) and the per-iteration mutable state (`RunState`)
  # both live in `Nest.Agents.Agent.LLMRunner`. The GenServer
  # constructs a `RunContext` from the Agent state in
  # `spawn_chat_task/3` and dispatches to `LLMRunner.run/2`.

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          client_config: ClientConfig.t(),
          vocation_id: integer() | nil,
          vocation: Vocations.Vocation.t() | nil,
          system_prompt: String.t() | nil,
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

    # Fetch vocation if provided; the Vocation struct is stored in
    # state so subsequent mode/caps resolution is a pure read of
    # the cached struct (no DB lookups on the per-message path).
    {system_prompt, mode, tool_names, vocation} =
      fetch_vocation_config(vocation_id, workspace_path)

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

        llm_metrics = %__MODULE__.LlmMetrics{
          context_limit: context_limit,
          context_limit_source: context_limit_source,
          usage_totals: Broadcasts.empty_usage_totals()
        }

        chat_state = %__MODULE__.ChatState{
          messages: initial_messages,
          next_message_index: next_index,
          streaming_acc: nil,
          status: :idle,
          active_message_index: 0
        }

        state = %__MODULE__{
          id: id,
          model: model,
          client_config: client_config,
          vocation: vocation,
          vocation_id: vocation_id,
          system_prompt: system_prompt,
          workspace_path: workspace_path,
          tmp_path: tmp_path,
          tools: tools,
          llm_metrics: llm_metrics,
          mode: mode,
          chat_state: chat_state
        }

        # Broadcast system message if present
        if system_prompt do
          Broadcasts.message(id, List.first(initial_messages))
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

    {user_message, llm_user_message} = build_user_messages(state, content, effective_mode)

    messages = state.chat_state.messages ++ [user_message]
    messages_for_llm = state.chat_state.messages ++ [llm_user_message]

    # Broadcast user message to all subscribers
    Broadcasts.message(state.id, user_message)

    state = apply_user_message_to_state(state, messages, effective_mode)
    Broadcasts.status(state.id, :streaming)

    # Pre-flight: does the next LLM call fit? If not, the
    # Compactor runs first (in a Task); the chat task spawns
    # after compaction completes.
    state = maybe_compact_then_chat(state, messages_for_llm, content, mode)

    {:noreply, state}
  end

  # Build the persisted user message (raw content + metadata.mode)
  # and the LLM-facing user message (with the mode prefixed into
  # the content). The persisted form is what gets broadcast and
  # saved; the LLM form is what the model sees on the next call.
  defp build_user_messages(state, content, effective_mode) do
    next_idx = state.chat_state.next_message_index
    user = %User{
      index: next_idx,
      timestamp: DateTime.utc_now(),
      content: content,
      metadata: %{"mode" => effective_mode},
      api_logs: get_pending_api_logs(state, next_idx)
    }

    llm_content = "[mode: #{effective_mode}]\n#{content}"
    user_message = {:user, user}
    llm_user_message = {:user, %{user | content: llm_content}}
    {user_message, llm_user_message}
  end

  # Mutate the chat_state to reflect the new user message:
  # append to history, advance the index, mark streaming,
  # reset pending API logs, and start a fresh streaming acc.
  defp apply_user_message_to_state(state, messages, _effective_mode) do
    next_idx = state.chat_state.next_message_index

    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            next_message_index: next_idx + 1,
            status: :streaming,
            active_message_index: next_idx,
            pending_api_logs:
              clear_pending_api_logs(state, next_idx).chat_state.pending_api_logs,
            streaming_acc: Streaming.new(next_idx + 1)
        }
    }
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
    if streaming_active?(state.chat_state.streaming_acc) do
      spawn_chat_task(state, content, mode)
    else
      case preflight_decision(messages_for_llm, state) do
        :fits ->
          spawn_chat_task(state, content, mode)

        :no_limit_known ->
          spawn_chat_task(state, content, mode)

        :needs_compaction ->
          Compaction.spawn(
            self(),
            state.client_config,
            state.llm_metrics.context_limit,
            messages_for_llm,
            {:chat_continuation, {content, mode}}
          )
      end
    end
  end

  defp spawn_chat_task(state, content, mode) do
    agent_pid = self()
    {effective_mode, caps} = resolve_mode_and_caps(mode, state.vocation_id)

    # handle_chat has already added the user message to state.chat_state.messages
    # and broadcast it. The last message in state.chat_state.messages is our
    # user message; we just need to construct the LLM-bound version
    # with the mode prefix.
    user_message = List.last(state.chat_state.messages)
    llm_user_message = llm_user_message(user_message, content, effective_mode)
    messages_for_llm = Enum.drop(state.chat_state.messages, -1) ++ [llm_user_message]

    Broadcasts.message(state.id, user_message)

    # handle_chat (or the compaction continuation) has already
    # set state.chat_state.streaming_acc to the correct index. Don't
    # overwrite it here — that would shift the assistant's index
    # by one.
    state = %{state | chat_state: %{state.chat_state | status: :streaming}}
    Broadcasts.status(state.id, :streaming)

    ctx = %LLMRunner.RunContext{
      client_config: state.client_config,
      tools: state.tools,
      system_prompt: state.system_prompt,
      messages: messages_for_llm,
      agent_pid: agent_pid,
      agent_id: state.id,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      context_limit_source: state.llm_metrics.context_limit_source
    }

    init_state = %LLMRunner.RunState{
      message_index: state.chat_state.streaming_acc.index,
      active_message_index: state.chat_state.active_message_index,
      api_log_sequences: state.chat_state.api_log_sequences,
      max_iterations: configured_max_tool_iterations()
    }

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      %LLMRunner.RunState{api_log_sequences: updated_sequences} =
        LLMRunner.run(ctx, init_state)

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
       index: state.chat_state.next_message_index,
       timestamp: DateTime.utc_now(),
       content: content,
       metadata: %{"mode" => effective_mode},
       api_logs: get_pending_api_logs(state, state.chat_state.next_message_index)
     }}
  end

  defp llm_user_message(user_message, content, effective_mode) do
    llm_content = "[mode: #{effective_mode}]\n#{content}"
    {:user, %{elem(user_message, 1) | content: llm_content}}
  end

  defp preflight_decision(messages_for_llm, state) do
    PreFlight.check_messages(messages_for_llm, state.llm_metrics.context_limit, 8_192)
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
  def handle_info({:delta_received, delta_content, part_type}, state) do
    # Accumulate delta using Streaming module based on content type
    acc = state.chat_state.streaming_acc

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

    {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
  end

  @impl true
  def handle_info({:thinking_signature_received, signature}, state) do
    # Anthropic's extended thinking emits a signature alongside the
    # thinking content. Stash it on the streaming accumulator so it
    # round-trips into the persisted assistant message's metadata.
    new_acc = %{state.chat_state.streaming_acc | thinking_signature: signature}
    {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
  end

  @impl true
  def handle_info({:llm_error, error_msg}, state) do
    # Finalize error message
    error_message =
      {:assistant,
       %Assistant{
         index: state.chat_state.streaming_acc.index,
         timestamp: DateTime.utc_now(),
         content: error_msg,
         thinking: nil,
         tool_calls: nil,
         api_logs: get_pending_api_logs(state, state.chat_state.streaming_acc.index)
       }}

    messages = state.chat_state.messages ++ [error_message]

    # Broadcast error message to all subscribers via PubSub
    Broadcasts.message(state.id, error_message)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            streaming_acc: nil,
            next_message_index: state.chat_state.next_message_index + 1,
            active_message_index: state.chat_state.streaming_acc.index,
            pending_api_logs:
              clear_pending_api_logs(state, state.chat_state.streaming_acc.index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.status(state.id, :idle)

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
    messages = state.chat_state.messages ++ [tool_call_message]

    # Broadcast tool call message
    Broadcasts.message(state.id, tool_call_message)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            next_message_index: state.chat_state.next_message_index + 1,
            pending_api_logs: clear_pending_api_logs(state, index).chat_state.pending_api_logs,
            status: :executing_tools
        }
    }

    Broadcasts.status(state.id, :executing_tools)

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
    messages = state.chat_state.messages ++ [tool_result_message]

    # Broadcast tool result message
    Broadcasts.message(state.id, tool_result_message)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            next_message_index: state.chat_state.next_message_index + 1,
            pending_api_logs: clear_pending_api_logs(state, index).chat_state.pending_api_logs,
            status: :streaming,
            streaming_acc: Streaming.new(state.chat_state.next_message_index + 1)
        }
    }

    Broadcasts.status(state.id, :streaming)

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_response_with_thinking, _response, thinking}, state) do
    # Finalize assistant message with thinking using Streaming.finalize
    assistant = Streaming.finalize(state.chat_state.streaming_acc)

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
         thinking_signature: state.chat_state.streaming_acc.thinking_signature,
         tool_calls: assistant.tool_calls,
         api_logs: get_pending_api_logs(state, state.chat_state.streaming_acc.index)
       }}

    messages = state.chat_state.messages ++ [final_message]

    # Broadcast completion to all subscribers via PubSub
    Broadcasts.message(state.id, final_message)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            streaming_acc: nil,
            next_message_index: state.chat_state.next_message_index + 1,
            active_message_index: state.chat_state.streaming_acc.index,
            pending_api_logs:
              clear_pending_api_logs(state, state.chat_state.streaming_acc.index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.status(state.id, :idle)

    {:noreply, state}
  end

  @impl true
  def handle_info({:api_log, message_index, api_log}, state) do
    # Check if message exists
    message =
      Enum.find(state.chat_state.messages, fn
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
    {:noreply, %{state | chat_state: %{state.chat_state | api_log_sequences: updated_sequences}}}
  end

  @impl true
  def handle_info({:discovered_context_limit, source, limit}, state) do
    # Update state with the discovered limit and broadcast a fresh
    # chat:status so the frontend can swap the chip's denominator from
    # the default to the real value.
    state = %{
      state
      | llm_metrics: %{state.llm_metrics | context_limit: limit, context_limit_source: source}
    }

    Broadcasts.status(state.id, state)
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
    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | usage_totals: Broadcasts.merge_usage_totals(state.llm_metrics.usage_totals, usage)
        }
    }

    Broadcasts.status(state.id, state)
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
      "Compaction complete: agent=#{state.id} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    # Archive the previous messages to history with a marker,
    # then replace state.chat_state.messages with the compacted state.
    state = archive_and_compact(state, new_messages)

    case continuation do
      {:chat_continuation, {content, mode}} ->
        # The compacted state replaced state.chat_state.messages; we need to
        # add the user's NEW message to history before the chat
        # task runs (mirroring handle_chat/3's logic).
        {effective_mode, _} = resolve_mode_and_caps(mode, state.vocation_id)

        user_message = build_user_message(state, content, effective_mode)
        Broadcasts.message(state.id, user_message)

        state = %{
          state
          | messages: state.chat_state.messages ++ [user_message],
            next_message_index: state.chat_state.next_message_index + 1,
            status: :streaming,
            active_message_index: state.chat_state.next_message_index,
            pending_api_logs:
              clear_pending_api_logs(state, state.chat_state.next_message_index).chat_state.pending_api_logs,
            streaming_acc: Streaming.new(state.chat_state.next_message_index + 1)
        }

        Broadcasts.status(state.id, :streaming)
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
    Compaction.spawn(
      self(),
      state.client_config,
      state.llm_metrics.context_limit,
      state.chat_state.messages || [],
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
      "compact_context tool: agent=#{state.id} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    state = archive_and_compact(state, new_messages)
    send(task_pid, {:compact_context_done, new_messages})
    {:noreply, state}
  end

  @impl true
  def handle_info({:preflight_request, task_pid, _messages_for_llm}, state) do
    # Called from the chat task right before each recursive LLM
    # call (after a tool iteration). Runs the pre-flight check
    # against the agent's *current* state.chat_state.messages (the source
    # of truth, since the task's snapshot may be stale by now).
    # If compaction is needed, spawns a compactor and the task
    # waits for the result; otherwise replies `:proceed` and the
    # task uses its current snapshot unchanged.
    if streaming_active?(state.chat_state.streaming_acc) do
      send(task_pid, {:preflight_result, :proceed, state.chat_state.messages || []})
      {:noreply, state}
    else
      case preflight_decision(state.chat_state.messages || [], state) do
        decision when decision in [:fits, :no_limit_known] ->
          send(task_pid, {:preflight_result, :proceed, state.chat_state.messages || []})
          {:noreply, state}

        :needs_compaction ->
          Compaction.spawn(
            self(),
            state.client_config,
            state.llm_metrics.context_limit,
            state.chat_state.messages || [],
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
    send(task_pid, {:preflight_result, :proceed, state.chat_state.messages || []})
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
      Enum.map(state.chat_state.messages, fn
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

    Broadcasts.message(state.id, updated_message)

    {:noreply, %{state | chat_state: %{state.chat_state | messages: messages}}}
  end

  defp handle_api_log_for_pending_message(state, message_index, api_log) do
    pending = Map.get(state.chat_state.pending_api_logs, message_index, [])

    pending_api_logs =
      Map.put(state.chat_state.pending_api_logs, message_index, pending ++ [api_log])

    {:noreply, %{state | chat_state: %{state.chat_state | pending_api_logs: pending_api_logs}}}
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

  defp fetch_vocation_config(nil, _workspace_path), do: {nil, "chat", [], nil}

  defp fetch_vocation_config(vocation_id, workspace_path) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        {nil, "chat", [], nil}

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

        {system_prompt, initial_mode, tools, vocation}
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

  defp get_pending_api_logs(state, message_index) do
    Map.get(state.chat_state.pending_api_logs, message_index, [])
  end

  defp clear_pending_api_logs(state, message_index) do
    %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs: Map.delete(state.chat_state.pending_api_logs, message_index)
        }
    }
  end
end
