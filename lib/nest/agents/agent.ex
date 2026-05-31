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
  alias LangChain.Message
  alias Nest.Agents.Registry
  alias Nest.ChatModel
  alias Nest.Tools
  alias Nest.Vocations

  defstruct [
    :id,
    :model,
    :chain,
    :vocation_id,
    :system_prompt,
    :workspace_path,
    :tools,
    mode: "chat",
    messages: [],
    next_message_index: 0,
    partial_message: nil,
    status: :idle,
    active_message_index: 0,
    api_call_sequences: %{},
    pending_api_logs: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          chain: LLMChain.t() | nil,
          vocation_id: integer() | nil,
          system_prompt: String.t() | nil,
          workspace_path: String.t() | nil,
          tools: [LangChain.Function.t()],
          mode: String.t(),
          messages: [map()],
          next_message_index: non_neg_integer(),
          partial_message: map() | nil,
          status: :idle | :streaming | :executing_tools,
          active_message_index: non_neg_integer(),
          api_call_sequences: %{non_neg_integer() => non_neg_integer()}
        }

  @type message :: %{
          index: non_neg_integer(),
          timestamp: DateTime.t(),
          role: :user | :assistant | :system | :tool,
          content: String.t(),
          tool_calls: [map()] | nil,
          tool_results: [map()] | nil,
          thinking: String.t() | nil,
          usage: map() | nil,
          api_logs: [map()]
        }

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
          partial: map() | nil
        }
  def get_public_info(pid) do
    GenServer.call(pid, :get_public_info)
  end

  @doc """
  Returns the message history for the agent.
  """
  @spec get_messages(pid()) :: [map()]
  def get_messages(pid) do
    GenServer.call(pid, :get_messages)
  end

  # Server Callbacks

  @impl true
  def init(attrs) do
    id = Map.fetch!(attrs, :id)
    model = Map.fetch!(attrs, :model)
    vocation_id = Map.get(attrs, :vocation_id)
    workspace_path = Map.get(attrs, :workspace_path)

    # Fetch vocation if provided
    {system_prompt, mode, tool_names} = fetch_vocation_config(vocation_id)

    # Get tools for the agent
    tools = Tools.get_functions(tool_names, workspace_path)

    # Create LLM chain from model config with system prompt and tools
    case create_chain(model, system_prompt, tools) do
      {:ok, chain} ->
        # Build initial messages with system prompt if present
        {initial_messages, next_index} =
          if system_prompt do
            system_message = %{
              index: 0,
              role: :system,
              content: system_prompt,
              timestamp: DateTime.utc_now(),
              tool_calls: nil,
              tool_results: nil,
              thinking: nil,
              usage: nil,
              api_logs: []
            }

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
          tools: tools,
          mode: mode,
          messages: initial_messages,
          next_message_index: next_index,
          partial_message: nil,
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
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:chat, content}, state) do
    # Add user message to history with index
    user_message = %{
      index: state.next_message_index,
      timestamp: DateTime.utc_now(),
      role: :user,
      content: content,
      tool_calls: nil,
      tool_results: nil,
      thinking: nil,
      usage: nil,
      api_logs: get_pending_api_logs(state, state.next_message_index)
    }

    messages = state.messages ++ [user_message]

    # Broadcast user message to all subscribers
    broadcast_message(state.id, user_message)

    # Update status to streaming
    state = %{
      state
      | messages: messages,
        next_message_index: state.next_message_index + 1,
        status: :streaming,
        active_message_index: user_message.index,
        pending_api_logs: clear_pending_api_logs(state, user_message.index).pending_api_logs,
        partial_message: %{
          index: state.next_message_index + 1,
          role: :assistant,
          content: "",
          tool_calls: nil,
          tool_results: nil,
          thinking: nil,
          usage: nil,
          timestamp: DateTime.utc_now(),
          # Streaming-related fields
          segments: [],
          current_type: nil,
          chars_sent: 0
        }
    }

    # Run LLM chain with callbacks in a task
    agent_pid = self()

    Task.start(fn ->
      # Initialize API call sequence counter for this Task
      Process.put(:api_call_sequence, 0)

      run_chain_with_callbacks(
        state.chain,
        messages,
        agent_pid,
        state.id,
        state.partial_message.index,
        state.active_message_index
      )
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
      partial: state.partial_message
    }

    {:reply, public_info, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_info({:delta_received, delta_content, part_type}, state) do
    # Accumulate delta into partial_message with segment tracking
    partial = state.partial_message

    # Initialize segments if empty
    segments = partial[:segments] || []

    # Check if we need to start a new segment or continue existing
    {current_type, current_content, segments} =
      if segments == [] do
        # First segment - initialize with proper content accumulation
        new_segment = %{type: part_type, content: delta_content}
        {part_type, partial.content <> delta_content, [new_segment]}
      else
        last_segment = List.last(segments)

        if last_segment.type == part_type do
          # Continue existing segment
          updated_segment = %{last_segment | content: last_segment.content <> delta_content}

          {part_type, partial.content <> delta_content,
           List.replace_at(segments, -1, updated_segment)}
        else
          # Start new segment
          new_segment = %{type: part_type, content: delta_content}
          {part_type, partial.content <> delta_content, segments ++ [new_segment]}
        end
      end

    new_partial = %{
      partial
      | content: current_content,
        segments: segments,
        current_type: current_type,
        chars_sent: String.length(current_content)
    }

    {:noreply, %{state | partial_message: new_partial}}
  end

  @impl true
  def handle_info({:llm_response, _message}, state) do
    # Finalize assistant message
    final_message = %{
      index: state.partial_message.index,
      timestamp: DateTime.utc_now(),
      role: :assistant,
      content: state.partial_message.content,
      tool_calls: nil,
      tool_results: nil,
      thinking: nil,
      usage: nil,
      api_logs: get_pending_api_logs(state, state.partial_message.index)
    }

    messages = state.messages ++ [final_message]

    # Broadcast completion to all subscribers via PubSub
    broadcast_message(state.id, final_message)

    state = %{
      state
      | messages: messages,
        partial_message: nil,
        next_message_index: state.next_message_index + 1,
        active_message_index: final_message.index,
        pending_api_logs: clear_pending_api_logs(state, final_message.index).pending_api_logs,
        status: :idle
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_error, error_msg}, state) do
    # Finalize error message
    error_message = %{
      index: state.partial_message.index,
      timestamp: DateTime.utc_now(),
      role: :assistant,
      content: error_msg,
      tool_calls: nil,
      tool_results: nil,
      thinking: nil,
      usage: nil,
      api_logs: get_pending_api_logs(state, state.partial_message.index)
    }

    messages = state.messages ++ [error_message]

    # Broadcast error message to all subscribers via PubSub
    broadcast_message(state.id, error_message)

    state = %{
      state
      | messages: messages,
        partial_message: nil,
        next_message_index: state.next_message_index + 1,
        active_message_index: error_message.index,
        pending_api_logs: clear_pending_api_logs(state, error_message.index).pending_api_logs,
        status: :idle
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:tool_calls_received, tool_call_message}, state) do
    # Apply any pending api_logs to the tool call message
    index = tool_call_message.index
    pending_logs = get_pending_api_logs(state, index)

    tool_call_message =
      if pending_logs != [] do
        %{tool_call_message | api_logs: tool_call_message.api_logs ++ pending_logs}
      else
        tool_call_message
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
  def handle_info({:tool_results_received, tool_result_message}, state) do
    # Apply any pending api_logs to the tool result message
    index = tool_result_message.index
    pending_logs = get_pending_api_logs(state, index)

    tool_result_message =
      if pending_logs != [] do
        %{tool_result_message | api_logs: tool_result_message.api_logs ++ pending_logs}
      else
        tool_result_message
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
        partial_message: %{
          index: state.next_message_index + 1,
          role: :assistant,
          content: "",
          tool_calls: nil,
          tool_results: nil,
          thinking: nil,
          usage: nil,
          timestamp: DateTime.utc_now(),
          # Streaming-related fields
          segments: [],
          current_type: nil,
          chars_sent: 0
        }
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:continue_after_tools, next_index}, state) do
    # Update partial message for the final response after tool execution
    state = %{
      state
      | partial_message: %{
          index: next_index,
          role: :assistant,
          content: "",
          tool_calls: nil,
          tool_results: nil,
          thinking: nil,
          usage: nil,
          timestamp: DateTime.utc_now(),
          # Streaming-related fields
          segments: [],
          current_type: nil,
          chars_sent: 0
        }
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_response_with_thinking, _response, thinking}, state) do
    # Finalize assistant message with thinking
    final_message = %{
      index: state.partial_message.index,
      timestamp: DateTime.utc_now(),
      role: :assistant,
      content: state.partial_message.content,
      tool_calls: nil,
      tool_results: nil,
      thinking: thinking,
      usage: nil,
      api_logs: get_pending_api_logs(state, state.partial_message.index)
    }

    messages = state.messages ++ [final_message]

    # Broadcast completion to all subscribers via PubSub
    broadcast_message(state.id, final_message)

    state = %{
      state
      | messages: messages,
        partial_message: nil,
        next_message_index: state.next_message_index + 1,
        active_message_index: final_message.index,
        pending_api_logs: clear_pending_api_logs(state, final_message.index).pending_api_logs,
        status: :idle
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:api_log, message_index, api_log}, state) do
    # Check if message exists
    message = Enum.find(state.messages, fn msg -> msg.index == message_index end)

    if message do
      handle_api_log_for_existing_message(state, message_index, api_log)
    else
      handle_api_log_for_pending_message(state, message_index, api_log)
    end
  end

  defp handle_api_log_for_existing_message(state, message_index, api_log) do
    messages =
      Enum.map(state.messages, fn msg ->
        if msg.index == message_index do
          %{msg | api_logs: msg.api_logs ++ [api_log]}
        else
          msg
        end
      end)

    updated_message = Enum.find(messages, fn msg -> msg.index == message_index end)
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

  defp run_chain_with_callbacks(
         chain,
         messages,
         agent_pid,
         agent_id,
         message_index,
         active_message_index
       ) do
    Logger.info("Agent #{agent_id} sending LLM request (message #{message_index})")

    # Convert messages and create chain with messages
    langchain_messages = convert_to_langchain_messages(messages)
    chain_with_messages = create_chain_with_messages(langchain_messages, chain)

    # Capture and broadcast API payload for OpenAI-compatible models
    if match?(%ChatOpenAI{}, chain.llm) do
      api_payload = ChatOpenAI.for_api(chain.llm, chain_with_messages.messages, chain.tools)
      broadcast_api_call(agent_pid, active_message_index, api_payload)
    end

    run_and_handle_response(
      chain_with_messages,
      agent_pid,
      agent_id,
      message_index,
      chain,
      active_message_index
    )
  end

  defp convert_to_langchain_messages(messages) do
    Enum.map(messages, &convert_message/1)
  end

  defp convert_message(msg) do
    role = msg[:role] || msg["role"]
    content = msg[:content] || msg["content"]

    convert_by_role(role, content, msg)
  end

  defp convert_by_role(:user, content, _msg), do: Message.new_user!(content)

  defp convert_by_role(:assistant, content, msg) do
    tool_calls = msg[:tool_calls] || msg["tool_calls"]
    convert_assistant_message(content, tool_calls)
  end

  defp convert_by_role(:tool, _content, msg) do
    tool_results = msg[:tool_results] || msg["tool_results"]
    convert_tool_message(tool_results)
  end

  defp convert_by_role(_, content, _msg), do: Message.new_user!(content)

  defp convert_assistant_message(content, nil) do
    Message.new_assistant!(content)
  end

  defp convert_assistant_message(content, tool_calls) do
    case tool_calls do
      [] ->
        Message.new_assistant!(content)

      calls ->
        lc_tool_calls = Enum.map(calls, &build_tool_call/1)
        Message.new_assistant!(%{content: content, tool_calls: lc_tool_calls})
    end
  end

  defp build_tool_call(tc) do
    %LangChain.Message.ToolCall{
      call_id: tc["id"] || tc[:id],
      name: tc["name"] || tc[:name],
      arguments: tc["arguments"] || tc[:arguments] || %{},
      status: :complete
    }
  end

  defp convert_tool_message(tool_results) do
    lc_tool_results = Enum.map(tool_results || [], &build_tool_result/1)
    Message.new_tool_result!(%{content: nil, tool_results: lc_tool_results})
  end

  defp build_tool_result(tr) do
    %LangChain.Message.ToolResult{
      tool_call_id: tr["tool_call_id"] || tr[:tool_call_id],
      name: tr["name"] || tr[:name],
      content: tr["content"] || tr[:content] || "",
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
         active_message_index
       ) do
    case LLMChain.run(chain, mode: :until_success) do
      {:ok, updated_chain} ->
        response = updated_chain.last_message

        # Broadcast API response for OpenAI-compatible models
        if match?(%ChatOpenAI{}, original_chain.llm) do
          api_response = build_api_response(response)
          broadcast_api_response(agent_pid, message_index, api_response)
        end

        handle_successful_response(
          response,
          updated_chain,
          agent_pid,
          agent_id,
          message_index,
          original_chain,
          active_message_index
        )

      {:error, _failed_chain, error} ->
        handle_failed_response(error, agent_pid, agent_id, message_index)
    end
  end

  defp handle_successful_response(
         response,
         chain,
         agent_pid,
         agent_id,
         message_index,
         _original_chain,
         active_message_index
       ) do
    # Check if this is a tool call
    if Message.is_tool_call?(response) do
      # Handle tool calls
      handle_tool_calls(response, chain, agent_pid, agent_id, message_index, active_message_index)
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
    end
  end

  defp handle_tool_calls(
         response,
         chain,
         agent_pid,
         agent_id,
         message_index,
         active_message_index
       ) do
    Logger.info("Agent #{agent_id} received tool calls (message #{message_index})")

    # Extract tool calls from response
    tool_calls =
      Enum.map(response.tool_calls, fn tc ->
        %{
          id: tc.call_id,
          name: tc.name,
          arguments: tc.arguments || %{}
        }
      end)

    # Broadcast tool call message immediately
    tool_call_message = %{
      index: message_index,
      timestamp: DateTime.utc_now(),
      role: :assistant,
      content: "",
      tool_calls: tool_calls,
      tool_results: nil,
      thinking: nil,
      usage: nil,
      api_logs: []
    }

    send(agent_pid, {:tool_calls_received, tool_call_message})

    # Execute tool calls (returns chain directly)
    try do
      chain_with_results = LLMChain.execute_tool_calls(chain, context: %{})

      # Extract tool results
      tool_results_message = chain_with_results.last_message

      tool_results =
        if tool_results_message.tool_results do
          Enum.map(tool_results_message.tool_results, fn tr ->
            %{
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
      tool_result_message = %{
        index: message_index + 1,
        timestamp: DateTime.utc_now(),
        role: :tool,
        content: format_tool_results_content(tool_results),
        tool_calls: nil,
        tool_results: tool_results,
        thinking: nil,
        usage: nil,
        api_logs: []
      }

      send(agent_pid, {:tool_results_received, tool_result_message})

      # Continue the conversation with tool results
      continue_with_tool_results(
        chain_with_results,
        agent_pid,
        agent_id,
        message_index + 2,
        active_message_index
      )
    catch
      error ->
        Logger.error("Tool execution failed: #{inspect(error)}")
        send(agent_pid, {:llm_error, "Tool execution failed: #{inspect(error)}"})
    end
  end

  defp format_tool_results_content(tool_results) do
    tool_results
    |> Enum.map_join("\n\n", fn tr ->
      status = if tr.is_error, do: "[ERROR]", else: "[SUCCESS]"
      "#{status} #{tr.name}: #{tr.content}"
    end)
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
         _active_message_index
       ) do
    # The chain now has the tool results, we need to call the LLM again
    # to get the final response based on the tool results

    Logger.info("Agent #{agent_id} continuing conversation after tool execution")

    # Get the last message (tool results) and convert to our format
    last_message = chain.last_message

    _tool_results =
      if last_message.tool_results do
        Enum.map(last_message.tool_results, fn tr ->
          %{
            tool_call_id: tr.tool_call_id,
            name: tr.name,
            content: extract_tool_content(tr.content),
            is_error: tr.is_error || false
          }
        end)
      else
        []
      end

    # Now we need to get the final assistant response
    # This requires running the chain again, but we're already in a Task
    # We need to set up the state for a new streaming response

    send(agent_pid, {:continue_after_tools, next_index})

    # Run the chain again to get the final response
    case LLMChain.run(chain, mode: :until_success) do
      {:ok, final_chain} ->
        final_response = final_chain.last_message

        # Broadcast API response for OpenAI-compatible models
        if match?(%ChatOpenAI{}, chain.llm) do
          api_response = build_api_response(final_response)
          broadcast_api_response(agent_pid, next_index, api_response)
        end

        # Extract thinking if present
        thinking = extract_thinking(final_response.content)

        # Extract segments
        segments = extract_content_segments(final_response.content)

        total_chars =
          segments
          |> Enum.filter(fn seg -> seg.type == :text end)
          |> Enum.map(&String.length(&1.content))
          |> Enum.sum()

        Logger.info(
          "Agent #{agent_id} received final response after tools (message #{next_index}): #{length(segments)} segments, #{total_chars} text chars"
        )

        # Stream the final response
        stream_segments(segments, agent_pid, agent_id, next_index)

        # Notify agent with final message including thinking
        send(agent_pid, {:llm_response_with_thinking, final_response, thinking})

      {:error, _failed_chain, error} ->
        handle_failed_response(error, agent_pid, agent_id, next_index)
    end
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

          # Also update agent's partial_message
          send(agent_pid, {:delta_received, chunk, segment.type})

          Process.sleep(50)
          chars_end
        end)

      chars_sent
    end)
  end

  defp handle_failed_response(error, agent_pid, agent_id, message_index) do
    error_msg = "Error: #{inspect(error)}"

    Logger.error("Agent #{agent_id} LLM request failed: #{error_msg}")

    # Broadcast error to all subscribers via PubSub
    broadcast_error(agent_id, message_index, error_msg)

    # Notify agent that streaming failed (similar to successful response)
    send(agent_pid, {:llm_error, error_msg})
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

  defp broadcast_api_call(agent_pid, message_index, api_payload) do
    api_call_id = get_next_api_call_id(message_index)

    send(
      agent_pid,
      {:api_log, message_index,
       %{
         id: api_call_id,
         timestamp: DateTime.utc_now(),
         type: :request,
         payload: api_payload
       }}
    )
  end

  defp broadcast_api_response(agent_pid, message_index, api_response) do
    api_call_id = get_next_api_call_id(message_index)

    send(
      agent_pid,
      {:api_log, message_index,
       %{
         id: api_call_id,
         timestamp: DateTime.utc_now(),
         type: :response,
         payload: api_response
       }}
    )
  end

  defp get_next_api_call_id(message_index) do
    sequence = Process.get(:api_call_sequence, 0)
    Process.put(:api_call_sequence, sequence + 1)
    :io_lib.format("~3..0B.~3..0B", [message_index, sequence]) |> IO.iodata_to_binary()
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
