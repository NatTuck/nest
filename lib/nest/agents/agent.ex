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

  defstruct [
    :id,
    :model,
    :chain,
    messages: [],
    next_message_index: 0,
    partial_message: nil,
    status: :idle
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          chain: LLMChain.t() | nil,
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

    # Create LLM chain from model config
    case create_chain(model) do
      {:ok, chain} ->
        state = %__MODULE__{
          id: id,
          model: model,
          chain: chain,
          messages: [],
          next_message_index: 0,
          partial_message: nil,
          status: :idle
        }

        Logger.info("Agent started: #{id}")
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
  def handle_info({:delta_received, delta_content}, state) do
    # Accumulate delta into partial_message
    partial = state.partial_message
    new_partial = %{partial | content: partial.content <> delta_content}
    {:noreply, %{state | partial_message: new_partial}}
  end

  @impl true
  def handle_info({:llm_response, _message}, state) do
    # Finalize assistant message
    final_message = %{
      index: state.partial_message.index,
      role: :assistant,
      content: state.partial_message.content,
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

  # Private functions

  defp create_chain(model) do
    model_name = model[:name] || model["name"]

    if model_name do
      ChatModel.new(model: model_name)
    else
      {:error, :no_model_name}
    end
  end

  defp run_chain_with_callbacks(chain, messages, agent_pid, agent_id, message_index) do
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
        handle_failed_response(error, agent_id, message_index)
    end
  end

  defp handle_successful_response(response, agent_pid, agent_id, message_index) do
    content = extract_content_text(response.content)

    stream_chunks(content, agent_pid, agent_id, message_index)

    # Notify agent that streaming is complete
    send(agent_pid, {:llm_response, response})
  end

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> part.type == :text end)
    |> Enum.map_join("", fn part -> part.content end)
  end

  defp extract_content_text(_content), do: ""

  defp handle_failed_response(error, agent_id, message_index) do
    error_msg = "Error: #{inspect(error)}"

    # Broadcast error to all subscribers via PubSub
    broadcast_error(agent_id, message_index, error_msg)
  end

  defp stream_chunks(content, agent_pid, agent_id, message_index) do
    chunks = chunk_content(content, 5)

    Enum.reduce(chunks, 0, fn chunk, chars_sent ->
      chars_end = chars_sent + String.length(chunk)

      # Broadcast delta to all subscribers via PubSub
      broadcast_delta(agent_id, message_index, chunk, chars_sent, chars_end)

      # Also update agent's partial_message
      send(agent_pid, {:delta_received, chunk})

      Process.sleep(50)
      chars_end
    end)
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

  defp broadcast_delta(agent_id, message_index, content, chars_start, chars_end) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_delta,
       %{
         index: message_index,
         content: content,
         chars_start: chars_start,
         chars_end: chars_end
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
