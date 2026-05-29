defmodule Nest.Agents.Agent do
  @moduledoc """
  GenServer that manages an individual agent's state and chat.

  Each agent runs as an independent process with:
  - A unique readable ID (e.g., "clever-raven")
  - Message history
  - LLM chain for model communication
  - Streaming broadcast support for real-time responses via PubSub
  """

  use GenServer, restart: :temporary

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias Nest.Agents.Registry
  alias Nest.ChatModel
  alias Nest.Vocations

  defstruct [
    :id,
    :model,
    :chain,
    :vocation_id,
    :system_prompt,
    :workspace_path,
    mode: "chat",
    messages: [],
    next_message_index: 0,
    partial_message: nil,
    status: :idle
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          chain: LLMChain.t() | nil,
          vocation_id: integer() | nil,
          system_prompt: String.t() | nil,
          workspace_path: String.t() | nil,
          mode: String.t(),
          messages: list(),
          next_message_index: non_neg_integer(),
          partial_message: map() | nil,
          status: :idle | :streaming
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
  Returns the current state of the agent.
  """
  @spec get_state(pid()) :: t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
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

  # Server Callbacks

  @impl true
  def init(attrs) do
    id = Map.fetch!(attrs, :id)
    model = Map.fetch!(attrs, :model)
    vocation_id = Map.get(attrs, :vocation_id)
    workspace_path = Map.get(attrs, :workspace_path)

    # Fetch vocation if provided
    {system_prompt, mode} = fetch_vocation_prompt_and_mode(vocation_id)

    # Create LLM chain from model config with system prompt
    case create_chain(model, system_prompt) do
      {:ok, chain} ->
        # Build initial messages with system prompt if present
        {initial_messages, next_index} =
          if system_prompt do
            system_message = %{
              index: 0,
              role: :system,
              content: system_prompt,
              timestamp: DateTime.utc_now()
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
          mode: mode,
          messages: initial_messages,
          next_message_index: next_index,
          partial_message: nil,
          status: :idle
        }

        # Broadcast system message if present
        if system_prompt do
          broadcast_message(id, List.first(initial_messages))
        end

        Logger.info(
          "Agent started: #{id} with vocation_id: #{inspect(vocation_id)}, mode: #{mode}"
        )

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:chat, content}, state) do
    # Add user message to history with index
    user_message = %{
      index: state.next_message_index,
      role: :user,
      content: content,
      timestamp: DateTime.utc_now()
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
        partial_message: %{
          index: state.next_message_index + 1,
          role: :assistant,
          content: "",
          segments: [],
          current_type: nil,
          chars_sent: 0,
          timestamp: DateTime.utc_now()
        }
    }

    # Run LLM chain with callbacks in a task
    agent_pid = self()

    Task.start(fn ->
      run_chain_with_callbacks(
        state.chain,
        messages,
        agent_pid,
        state.id,
        state.partial_message.index
      )
    end)

    {:noreply, state}
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
    # Finalize assistant message with segments
    final_message = %{
      index: state.partial_message.index,
      role: :assistant,
      content: state.partial_message.content,
      segments: state.partial_message.segments,
      timestamp: DateTime.utc_now()
    }

    messages = state.messages ++ [final_message]

    # Broadcast completion to all subscribers via PubSub
    broadcast_message(state.id, final_message)

    state = %{
      state
      | messages: messages,
        partial_message: nil,
        next_message_index: state.next_message_index + 1,
        status: :idle
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_error, error_msg}, state) do
    # Finalize error message
    error_message = %{
      index: state.partial_message.index,
      role: :assistant,
      content: error_msg,
      timestamp: DateTime.utc_now()
    }

    messages = state.messages ++ [error_message]

    # Broadcast error message to all subscribers via PubSub
    broadcast_message(state.id, error_message)

    state = %{
      state
      | messages: messages,
        partial_message: nil,
        next_message_index: state.next_message_index + 1,
        status: :idle
    }

    {:noreply, state}
  end

  # Private functions

  defp create_chain(model, system_prompt) do
    model_name = model[:name] || model["name"]

    if model_name do
      opts = [model: model_name]

      opts =
        if system_prompt do
          Keyword.put(opts, :system_prompt, system_prompt)
        else
          opts
        end

      ChatModel.new(opts)
    else
      {:error, :no_model_name}
    end
  end

  defp fetch_vocation_prompt_and_mode(nil), do: {nil, "chat"}

  defp fetch_vocation_prompt_and_mode(vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        {nil, "chat"}

      vocation ->
        initial_mode = get_initial_mode(vocation.modes)
        {vocation.system_prompt, initial_mode}
    end
  end

  defp get_initial_mode(nil), do: "chat"

  defp get_initial_mode(%{} = modes) when map_size(modes) > 0 do
    modes |> Map.keys() |> List.first()
  end

  defp get_initial_mode(_), do: "chat"

  defp run_chain_with_callbacks(chain, messages, agent_pid, agent_id, message_index) do
    Logger.info("Agent #{agent_id} sending LLM request (message #{message_index})")

    messages
    |> convert_to_langchain_messages()
    |> create_chain_with_messages(chain)
    |> run_and_handle_response(agent_pid, agent_id, message_index)
  end

  defp convert_to_langchain_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]

      case role do
        :user -> Message.new_user!(content)
        :assistant -> Message.new_assistant!(content)
        _ -> Message.new_user!(content)
      end
    end)
  end

  defp create_chain_with_messages(langchain_messages, chain) do
    new_chain = LLMChain.new!(%{llm: chain.llm})

    # Add messages one by one using add_message
    Enum.reduce(langchain_messages, new_chain, fn msg, acc_chain ->
      LLMChain.add_message(acc_chain, msg)
    end)
  end

  defp run_and_handle_response(chain, agent_pid, agent_id, message_index) do
    case LLMChain.run(chain) do
      {:ok, updated_chain} ->
        response = updated_chain.last_message
        handle_successful_response(response, agent_pid, agent_id, message_index)

      {:error, _failed_chain, error} ->
        handle_failed_response(error, agent_pid, agent_id, message_index)
    end
  end

  defp handle_successful_response(response, agent_pid, agent_id, message_index) do
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
      {:chat_error, %{index: message_index, content: error_msg}}
    )
  end
end
