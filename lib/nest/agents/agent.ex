defmodule Nest.Agents.Agent do
  @moduledoc """
  GenServer that manages an individual agent's state and chat.

  Each agent runs as an independent process with:
  - A unique readable ID (e.g., "clever-raven")
  - Message history with tool calling support
  - LLM chain for model communication with tool execution
  - Streaming broadcast support for real-time responses via PubSub
  """

  use GenServer, restart: :temporary

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message, as: LangChainMessage
  alias Nest.Agents.Registry
  alias Nest.ChatModel
  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.Streaming
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User
  alias Nest.Tools
  alias Nest.Vocations

  defstruct [
    :id,
    :model,
    :chain,
    :vocation_id,
    :system_prompt,
    :workspace_path,
    :tmp_path,
    :tools,
    mode: "chat",
    messages: [],
    next_message_index: 0,
    streaming_acc: nil,
    status: :idle,
    active_message_index: 0,
    api_log_sequences: %{},
    pending_api_logs: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          chain: LLMChain.t() | nil,
          vocation_id: integer() | nil,
          system_prompt: String.t() | nil,
          workspace_path: String.t() | nil,
          tmp_path: String.t() | nil,
          tools: [LangChain.Function.t()],
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
  """
  @spec chat(pid(), String.t()) :: :ok
  def chat(pid, content) do
    GenServer.cast(pid, {:chat, content})
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
    {system_prompt, mode, tool_names} = fetch_vocation_config(vocation_id)

    # Create per-agent tmp space
    tmp_path = create_tmp_space(id)

    # Get tools for the agent (with tmp_path for sandbox)
    tools = Tools.get_functions(tool_names, workspace_path, tmp_path)

    # Create LLM chain from model config with system prompt and tools
    case create_chain(model, system_prompt, tools) do
      {:ok, chain} ->
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
          chain: chain,
          vocation_id: vocation_id,
          system_prompt: system_prompt,
          workspace_path: workspace_path,
          tmp_path: tmp_path,
          tools: tools,
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

        Logger.info(
          "Agent started: #{id} with vocation_id: #{inspect(vocation_id)}, mode: #{mode}, tools: #{length(tools)}"
        )

        {:ok, state}

      {:error, reason} ->
        # Clean up tmp space if chain creation fails
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
    # Add user message to history with index
    user_message =
      {:user,
       %User{
         index: state.next_message_index,
         timestamp: DateTime.utc_now(),
         content: content,
         api_logs: get_pending_api_logs(state, state.next_message_index)
       }}

    messages = state.messages ++ [user_message]

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

    # Run LLM chain with callbacks in a task
    agent_pid = self()

    Task.start(fn ->
      updated_sequences =
        run_chain_with_callbacks(
          state.chain,
          messages,
          agent_pid,
          state.id,
          state.streaming_acc.index,
          state.active_message_index,
          state.api_log_sequences
        )

      # Send updated sequences back to agent
      send(agent_pid, {:api_log_sequences_updated, updated_sequences})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_public_info, _from, state) do
    public_info = %{
      id: state.id,
      model: state.model,
      message_count: length(state.messages),
      status: state.status,
      vocation_id: state.vocation_id,
      tmp_path: state.tmp_path,
      partial: state.streaming_acc
    }

    {:reply, public_info, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
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
  def handle_info({:llm_response, _message}, state) do
    # Finalize assistant message using Streaming.finalize
    assistant = Streaming.finalize(state.streaming_acc)

    final_message =
      {:assistant,
       %Assistant{
         index: assistant.index,
         timestamp: DateTime.utc_now(),
         content: assistant.content,
         thinking: assistant.thinking,
         tool_calls: assistant.tool_calls,
         api_logs: get_pending_api_logs(state, assistant.index)
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

    {:noreply, state}
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

    {:noreply, state}
  end

  @impl true
  def handle_info({:continue_after_tools, next_index}, state) do
    # Update streaming accumulator for the final response after tool execution
    state = %{
      state
      | streaming_acc: Streaming.new(next_index)
    }

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

  defp create_chain(model, system_prompt, tools) do
    model_name = model[:name] || model["name"]

    if model_name do
      opts = [model: model_name]

      opts =
        if system_prompt do
          Keyword.put(opts, :system_prompt, system_prompt)
        else
          opts
        end

      case ChatModel.new(opts) do
        {:ok, chain} ->
          # Add tools to the chain
          chain_with_tools = LLMChain.add_tools(chain, tools)
          {:ok, chain_with_tools}

        error ->
          error
      end
    else
      {:error, :no_model_name}
    end
  end

  defp fetch_vocation_config(nil), do: {nil, "chat", []}

  defp fetch_vocation_config(vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        {nil, "chat", []}

      vocation ->
        initial_mode = get_initial_mode(vocation.modes)
        tools = vocation.tools || []
        {vocation.system_prompt, initial_mode, tools}
    end
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

  defp run_chain_with_callbacks(
         chain,
         messages,
         agent_pid,
         agent_id,
         message_index,
         active_message_index,
         api_log_sequences
       ) do
    Logger.info("Agent #{agent_id} sending LLM request (message #{message_index})")

    # Convert messages and create chain with messages
    langchain_messages = convert_to_langchain_messages(messages)
    chain_with_messages = create_chain_with_messages(langchain_messages, chain)

    # Capture and broadcast API payload for OpenAI-compatible models
    api_log_sequences =
      if match?(%ChatOpenAI{}, chain.llm) do
        api_payload = ChatOpenAI.for_api(chain.llm, chain_with_messages.messages, chain.tools)

        {api_log_id, updated_sequences} =
          get_next_api_log_id(active_message_index, api_log_sequences)

        broadcast_api_log(agent_pid, active_message_index, api_log_id, api_payload)
        updated_sequences
      else
        api_log_sequences
      end

    run_and_handle_response(
      chain_with_messages,
      agent_pid,
      agent_id,
      message_index,
      chain,
      active_message_index,
      api_log_sequences
    )
  end

  defp convert_to_langchain_messages(messages) do
    Enum.map(messages, &convert_message/1)
  end

  defp convert_message({:user, %User{} = msg}) do
    LangChainMessage.new_user!(msg.content)
  end

  defp convert_message({:assistant, %Assistant{} = msg}) do
    convert_assistant_message(msg.content, msg.tool_calls)
  end

  defp convert_message({:tool, %Tool{} = msg}) do
    lc_tool_results = Enum.map(msg.tool_results, &build_tool_result/1)
    LangChainMessage.new_tool_result!(%{content: nil, tool_results: lc_tool_results})
  end

  defp convert_message({:system, %System{} = msg}) do
    LangChainMessage.new_system!(msg.content)
  end

  defp convert_assistant_message(content, nil) do
    LangChainMessage.new_assistant!(content)
  end

  defp convert_assistant_message(content, tool_calls) do
    case tool_calls do
      [] ->
        LangChainMessage.new_assistant!(content)

      calls ->
        lc_tool_calls = Enum.map(calls, &build_tool_call/1)
        LangChainMessage.new_assistant!(%{content: content, tool_calls: lc_tool_calls})
    end
  end

  defp build_tool_call(%ToolCall{} = tc) do
    %LangChainMessage.ToolCall{
      call_id: tc.id,
      name: tc.name,
      arguments: tc.arguments || %{},
      status: :complete
    }
  end

  defp build_tool_call(tc) when is_map(tc) do
    %LangChainMessage.ToolCall{
      call_id: tc["id"] || tc[:id],
      name: tc["name"] || tc[:name],
      arguments: tc["arguments"] || tc[:arguments] || %{},
      status: :complete
    }
  end

  defp build_tool_result(%ToolResult{} = tr) do
    content_parts =
      if is_binary(tr.content) do
        [%LangChain.Message.ContentPart{type: :text, content: tr.content}]
      else
        tr.content
      end

    %LangChainMessage.ToolResult{
      tool_call_id: tr.tool_call_id,
      name: tr.name,
      content: content_parts,
      is_error: tr.is_error
    }
  end

  defp build_tool_result(tr) when is_map(tr) do
    raw_content = tr["content"] || tr[:content] || ""

    content_parts =
      if is_binary(raw_content) do
        [%LangChain.Message.ContentPart{type: :text, content: raw_content}]
      else
        raw_content
      end

    %LangChainMessage.ToolResult{
      tool_call_id: tr["tool_call_id"] || tr[:tool_call_id],
      name: tr["name"] || tr[:name],
      content: content_parts,
      is_error: tr["is_error"] || tr[:is_error] || false
    }
  end

  defp create_chain_with_messages(langchain_messages, chain) do
    new_chain = LLMChain.new!(%{llm: chain.llm})

    # Add tools from the original chain
    new_chain = LLMChain.add_tools(new_chain, chain.tools)

    # Add messages one by one using add_message
    Enum.reduce(langchain_messages, new_chain, fn msg, acc_chain ->
      LLMChain.add_message(acc_chain, msg)
    end)
  end

  defp run_and_handle_response(
         chain,
         agent_pid,
         agent_id,
         message_index,
         original_chain,
         active_message_index,
         api_log_sequences
       ) do
    case LLMChain.run(chain) do
      {:ok, updated_chain} ->
        response = updated_chain.last_message

        # Broadcast API response for OpenAI-compatible models
        api_log_sequences =
          if match?(%ChatOpenAI{}, original_chain.llm) do
            api_response = build_api_response(response)

            {api_log_id, updated_sequences} =
              get_next_api_log_id(message_index, api_log_sequences)

            broadcast_api_response(agent_pid, message_index, api_log_id, api_response)
            updated_sequences
          else
            api_log_sequences
          end

        handle_successful_response(
          response,
          updated_chain,
          agent_pid,
          agent_id,
          message_index,
          original_chain,
          active_message_index,
          api_log_sequences
        )

      {:error, _failed_chain, error} ->
        handle_failed_response(error, agent_pid, agent_id, message_index, api_log_sequences)
    end
  end

  defp handle_successful_response(
         response,
         chain,
         agent_pid,
         agent_id,
         message_index,
         _original_chain,
         active_message_index,
         api_log_sequences
       ) do
    # Check if this is a tool call
    if LangChainMessage.is_tool_call?(response) do
      # Handle tool calls - start with max 5 iterations
      handle_tool_calls(
        response,
        chain,
        agent_pid,
        agent_id,
        message_index,
        active_message_index,
        5,
        api_log_sequences
      )
    else
      # Regular text response
      segments = extract_content_segments(response.content)

      total_chars =
        segments
        |> Enum.filter(fn seg -> seg.type == :text end)
        |> Enum.map(&String.length(&1.content))
        |> Enum.sum()

      Logger.info(
        "Agent #{agent_id} received LLM response (message #{message_index}): #{length(segments)} segments, #{total_chars} text chars"
      )

      stream_segments(segments, agent_pid, agent_id, message_index)

      # Notify agent that streaming is complete
      send(agent_pid, {:llm_response, response})
      api_log_sequences
    end
  end

  defp handle_tool_calls(
         response,
         chain,
         agent_pid,
         agent_id,
         message_index,
         active_message_index,
         max_iterations,
         api_log_sequences
       ) do
    Logger.info(
      "Agent #{agent_id} received tool calls (message #{message_index}, iteration #{max_iterations})"
    )

    # Extract tool calls from response
    tool_calls =
      Enum.map(response.tool_calls, fn tc ->
        %ToolCall{
          id: tc.call_id,
          name: tc.name,
          arguments: tc.arguments || %{}
        }
      end)

    # Extract text content from the response (if any)
    text_content = extract_text_content(response.content)

    # Broadcast tool call message immediately
    tool_call_message =
      {:assistant,
       %Assistant{
         index: message_index,
         timestamp: DateTime.utc_now(),
         content: text_content,
         tool_calls: tool_calls,
         api_logs: []
       }}

    send(agent_pid, {:tool_calls_received, tool_call_message})

    # Execute tool calls (returns chain directly)
    try do
      chain_with_results = LLMChain.execute_tool_calls(chain, context: %{}, max_iterations: 5)

      # Extract tool results
      tool_results_message = chain_with_results.last_message

      tool_results =
        if tool_results_message.tool_results do
          Enum.map(tool_results_message.tool_results, fn tr ->
            %ToolResult{
              tool_call_id: tr.tool_call_id,
              name: tr.name,
              content: extract_tool_content(tr.content),
              is_error: tr.is_error || false
            }
          end)
        else
          []
        end

      # Broadcast tool results
      tool_result_message =
        {:tool,
         %Tool{
           index: message_index + 1,
           timestamp: DateTime.utc_now(),
           tool_results: tool_results,
           api_logs: []
         }}

      send(agent_pid, {:tool_results_received, tool_result_message})

      # Continue the conversation with tool results, decrementing the iteration counter
      continue_with_tool_results(
        chain_with_results,
        agent_pid,
        agent_id,
        message_index + 2,
        active_message_index,
        max_iterations - 1,
        api_log_sequences
      )
    catch
      error ->
        Logger.error("Tool execution failed: #{inspect(error)}")
        send(agent_pid, {:llm_error, "Tool execution failed: #{inspect(error)}"})
        api_log_sequences
    end
  end

  # Extract content from LangChain.Message.ContentPart structs or plain text
  defp extract_tool_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %LangChain.Message.ContentPart{type: :text, content: text} -> text
      %LangChain.Message.ContentPart{} = part -> inspect(part)
      other -> to_string(other)
    end)
  end

  defp extract_tool_content(content), do: to_string(content)

  defp continue_with_tool_results(
         chain,
         agent_pid,
         agent_id,
         next_index,
         active_message_index,
         max_iterations,
         api_log_sequences
       ) do
    # The chain now has the tool results, we need to call the LLM again
    # to get the final response based on the tool results

    Logger.info(
      "Agent #{agent_id} continuing conversation after tool execution (#{max_iterations} iterations remaining)"
    )

    # Set up the state for a new streaming response
    send(agent_pid, {:continue_after_tools, next_index})

    # Run the chain to get the final response
    # Use explicit iteration with max limit instead of :while_needs_response
    # to avoid hidden loop complexity and make migration easier
    run_with_tool_handling(
      chain,
      agent_pid,
      agent_id,
      next_index,
      active_message_index,
      max_iterations,
      api_log_sequences
    )
  end

  # Run chain with explicit tool handling and iteration limit
  # max_iterations prevents infinite loops with tool-happy LLMs
  defp run_with_tool_handling(
         chain,
         agent_pid,
         agent_id,
         message_index,
         active_message_index,
         max_iterations,
         api_log_sequences
       ) do
    if max_iterations <= 0 do
      Logger.warning("Agent #{agent_id} reached max tool iterations, returning last response")

      handle_failed_response(
        "Max tool iterations reached",
        agent_pid,
        agent_id,
        message_index,
        api_log_sequences
      )
    else
      run_chain_and_handle_response(
        chain,
        agent_pid,
        agent_id,
        message_index,
        active_message_index,
        max_iterations,
        api_log_sequences
      )
    end
  end

  # Execute chain run and route response handling
  defp run_chain_and_handle_response(
         chain,
         agent_pid,
         agent_id,
         message_index,
         active_message_index,
         max_iterations,
         api_log_sequences
       ) do
    # Capture and broadcast API payload for OpenAI-compatible models
    # Include all messages to transparently show the actual API request
    api_log_sequences =
      if match?(%ChatOpenAI{}, chain.llm) do
        api_payload = ChatOpenAI.for_api(chain.llm, chain.messages, chain.tools)

        # Determine which message should receive the API request log.
        # When tool results are being sent back to the API (chain contains tool messages),
        # the API request log belongs to the tool message (message_index - 1).
        # Otherwise, it's for the upcoming assistant message (message_index).
        last_message = List.last(chain.messages)

        api_log_target_index =
          if last_message && last_message.role == :tool do
            message_index - 1
          else
            message_index
          end

        {api_log_id, updated_sequences} =
          get_next_api_log_id(api_log_target_index, api_log_sequences)

        broadcast_api_log(agent_pid, api_log_target_index, api_log_id, api_payload)
        updated_sequences
      else
        api_log_sequences
      end

    case LLMChain.run(chain) do
      {:ok, updated_chain} ->
        handle_run_response(
          updated_chain,
          agent_pid,
          agent_id,
          message_index,
          active_message_index,
          max_iterations,
          api_log_sequences
        )

      {:error, _failed_chain, error} ->
        handle_failed_response(error, agent_pid, agent_id, message_index, api_log_sequences)
    end
  end

  # Handle successful LLM run response - check for tool calls or finalize
  defp handle_run_response(
         updated_chain,
         agent_pid,
         agent_id,
         message_index,
         active_message_index,
         max_iterations,
         api_log_sequences
       ) do
    response = updated_chain.last_message

    if LangChainMessage.is_tool_call?(response) do
      Logger.info(
        "Agent #{agent_id} received additional tool calls in iteration #{max_iterations}"
      )

      handle_tool_calls(
        response,
        updated_chain,
        agent_pid,
        agent_id,
        message_index,
        active_message_index,
        max_iterations,
        api_log_sequences
      )
    else
      finalize_tool_response(
        updated_chain,
        response,
        agent_pid,
        agent_id,
        message_index,
        api_log_sequences
      )
    end
  end

  # Finalize the response after all tools are executed
  defp finalize_tool_response(
         chain,
         response,
         agent_pid,
         agent_id,
         message_index,
         api_log_sequences
       ) do
    # Broadcast API response for OpenAI-compatible models
    api_log_sequences =
      if match?(%ChatOpenAI{}, chain.llm) do
        api_response = build_api_response(response)
        {api_log_id, updated_sequences} = get_next_api_log_id(message_index, api_log_sequences)
        broadcast_api_response(agent_pid, message_index, api_log_id, api_response)
        updated_sequences
      else
        api_log_sequences
      end

    # Extract thinking if present
    thinking = extract_thinking(response.content)

    # Extract segments
    segments = extract_content_segments(response.content)

    total_chars =
      segments
      |> Enum.filter(fn seg -> seg.type == :text end)
      |> Enum.map(&String.length(&1.content))
      |> Enum.sum()

    Logger.info(
      "Agent #{agent_id} received final response after tools (message #{message_index}): #{length(segments)} segments, #{total_chars} text chars"
    )

    # Stream the final response
    stream_segments(segments, agent_pid, agent_id, message_index)

    # Notify agent with final message including thinking
    send(agent_pid, {:llm_response_with_thinking, response, thinking})

    api_log_sequences
  end

  defp extract_thinking(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> match?(%{type: :thinking}, part) end)
    |> Enum.map_join("\n", & &1.content)
    |> case do
      "" -> nil
      thinking -> thinking
    end
  end

  defp extract_thinking(_content), do: nil

  # Extract text content from response
  defp extract_text_content(content) when is_binary(content) do
    content
  end

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> match?(%{type: :text}, part) end)
    |> Enum.map_join("", fn %{content: text} -> text end)
  end

  defp extract_text_content(_content), do: ""

  # Extract content as segments with type information
  defp extract_content_segments(content) when is_binary(content) do
    [%{type: :text, content: content}]
  end

  defp extract_content_segments(content) when is_list(content) do
    Enum.flat_map(content, &part_to_segment/1)
  end

  defp extract_content_segments(_content), do: []

  # Convert a single ContentPart to a segment
  defp part_to_segment(%{type: :text, content: content})
       when is_binary(content) and content != "",
       do: [%{type: :text, content: content}]

  defp part_to_segment(%{type: :text}), do: []

  defp part_to_segment(%{type: :thinking, content: content})
       when is_binary(content) and content != "",
       do: [%{type: :thinking, content: content}]

  defp part_to_segment(%{type: :thinking}), do: []

  defp part_to_segment(%{type: :unsupported}),
    do: [%{type: :unsupported, content: "[redacted thinking]"}]

  defp part_to_segment(%{type: :image}),
    do: [%{type: :unsupported, content: "[image]"}]

  defp part_to_segment(%{type: :image_url}),
    do: [%{type: :unsupported, content: "[image]"}]

  defp part_to_segment(%{type: :file}),
    do: [%{type: :unsupported, content: "[file attachment]"}]

  defp part_to_segment(%{type: :file_url}),
    do: [%{type: :unsupported, content: "[file attachment]"}]

  defp part_to_segment(_), do: []

  # Stream each segment separately with type information
  defp stream_segments(segments, agent_pid, agent_id, message_index) do
    Enum.reduce(segments, 0, fn segment, chars_sent ->
      chunks = chunk_content(segment.content, 5)

      chars_sent =
        Enum.reduce(chunks, chars_sent, fn chunk, acc ->
          chars_end = acc + String.length(chunk)

          # Broadcast delta with type information
          broadcast_delta(agent_id, message_index, chunk, acc, chars_end, segment.type)

          # Also update agent's streaming accumulator
          send(agent_pid, {:delta_received, chunk, segment.type})

          Process.sleep(50)
          chars_end
        end)

      chars_sent
    end)
  end

  defp handle_failed_response(error, agent_pid, agent_id, message_index, api_log_sequences) do
    error_msg = "Error: #{inspect(error)}"

    Logger.error("Agent #{agent_id} LLM request failed: #{error_msg}")

    # Broadcast error to all subscribers via PubSub
    broadcast_error(agent_id, message_index, error_msg)

    # Notify agent that streaming failed (similar to successful response)
    send(agent_pid, {:llm_error, error_msg})

    api_log_sequences
  end

  defp chunk_content(content, size) do
    content
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  # PubSub broadcast helpers

  defp broadcast_message(agent_id, message) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_message, message}
    )
  end

  defp broadcast_delta(agent_id, message_index, content, chars_start, chars_end, part_type) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_delta,
       %{
         index: message_index,
         content: content,
         chars_start: chars_start,
         chars_end: chars_end,
         part_type: part_type
       }}
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

  defp build_api_response(response) do
    %{
      role: response.role,
      content: response.content,
      tool_calls: response.tool_calls,
      tool_results: response.tool_results,
      index: response.index,
      status: response.status
    }
  end

  defp get_pending_api_logs(state, message_index) do
    Map.get(state.pending_api_logs, message_index, [])
  end

  defp clear_pending_api_logs(state, message_index) do
    %{state | pending_api_logs: Map.delete(state.pending_api_logs, message_index)}
  end
end
