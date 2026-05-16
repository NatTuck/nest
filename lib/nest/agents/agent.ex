defmodule Nest.Agents.Agent do
  @moduledoc """
  GenServer that manages an individual agent's state and chat.

  Each agent runs as an independent process with:
  - A unique readable ID (e.g., "clever-raven")
  - Message history
  - LLM chain for model communication
  - Streaming callback support for real-time responses
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
    :channel_pid,
    messages: [],
    status: :idle
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          model: map(),
          chain: LLMChain.t() | nil,
          channel_pid: pid() | nil,
          messages: list(),
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
  Sets the channel PID for streaming callbacks.

  The channel will receive delta and message broadcasts during chat.
  """
  @spec set_channel(pid(), pid()) :: :ok
  def set_channel(pid, channel_pid) do
    GenServer.cast(pid, {:set_channel, channel_pid})
  end

  @doc """
  Sends a chat message to the agent.

  The message is added to the chain and triggers a streaming response
  from the LLM. Responses are broadcast to the channel.
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
          channel_pid: nil,
          messages: [],
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
  def handle_cast({:set_channel, channel_pid}, state) do
    {:noreply, %{state | channel_pid: channel_pid}}
  end

  @impl true
  def handle_cast({:chat, content}, state) do
    # Add user message to history
    user_message = %{role: :user, content: content}
    messages = state.messages ++ [user_message]

    # Update status to streaming
    state = %{state | messages: messages, status: :streaming}

    # Run LLM chain with callbacks in a task
    Task.start(fn ->
      run_chain_with_callbacks(state.chain, messages, state.channel_pid, state.id)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_response, message}, state) do
    # Add assistant message to history
    messages = state.messages ++ [message]
    state = %{state | messages: messages, status: :idle}
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

  defp run_chain_with_callbacks(nil, _messages, _channel_pid, agent_id) do
    Logger.error("Cannot run chain for #{agent_id}: chain not initialized")
  end

  defp run_chain_with_callbacks(chain, messages, channel_pid, _agent_id) do
    messages
    |> convert_to_langchain_messages()
    |> create_chain_with_messages(chain)
    |> run_and_handle_response(channel_pid)
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

  defp run_and_handle_response(chain, channel_pid) do
    case LLMChain.run(chain) do
      {:ok, updated_chain} ->
        response = updated_chain.last_message
        handle_successful_response(response, channel_pid)

      {:error, _failed_chain, error} ->
        handle_failed_response(error, channel_pid)
    end
  end

  defp handle_successful_response(response, channel_pid) do
    content = extract_content_text(response.content)

    if channel_pid && Process.alive?(channel_pid) do
      stream_chunks(content, channel_pid)
      send(channel_pid, {:message, %{role: :assistant, content: content}})
    end
  end

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> part.type == :text end)
    |> Enum.map_join("", fn part -> part.content end)
  end

  defp extract_content_text(_content), do: ""

  defp handle_failed_response(error, channel_pid) do
    error_msg = "Error: #{inspect(error)}"

    if channel_pid && Process.alive?(channel_pid) do
      send(
        channel_pid,
        {:message, %{role: :assistant, content: error_msg}}
      )
    end
  end

  defp stream_chunks(content, channel_pid) do
    chunks = chunk_content(content, 5)

    Enum.each(chunks, fn chunk ->
      send(channel_pid, {:delta, chunk})
      Process.sleep(50)
    end)
  end

  defp chunk_content(content, size) do
    content
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end
end
