defmodule Nest.LangChainMock do
  @moduledoc """
  Complete mock implementation of LangChain.Chains.LLMChain for testing.

  This mock implements all the functions needed by the application without
  delegating to the original module, avoiding unexpected side effects.
  """

  alias LangChain.Message

  @doc """
  Creates a new LLMChain with the given attributes.
  Only requires :llm to be set.
  """
  def new(attrs \\ %{}) do
    chain = build_chain_struct(attrs)

    if chain.llm == nil do
      {:error, %{errors: [llm: {"can't be blank", [validation: :required]}]}}
    else
      {:ok, chain}
    end
  end

  defp build_chain_struct(attrs) do
    %{
      __struct__: LangChain.Chains.LLMChain,
      llm: attrs[:llm],
      verbose: attrs[:verbose] || false,
      verbose_deltas: attrs[:verbose_deltas] || false,
      tools: attrs[:tools] || [],
      _tool_map: %{},
      messages: attrs[:messages] || [],
      custom_context: attrs[:custom_context],
      message_processors: attrs[:message_processors] || [],
      max_retry_count: attrs[:max_retry_count] || 3,
      current_failure_count: 0,
      delta: nil,
      last_message: nil,
      exchanged_messages: [],
      needs_response: false,
      async_tool_timeout: attrs[:async_tool_timeout] || :infinity,
      callbacks: attrs[:callbacks] || []
    }
  end

  @doc """
  Creates a new LLMChain or raises on error.
  """
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, chain} -> chain
      {:error, changeset} -> raise LangChain.LangChainError, changeset
    end
  end

  @doc """
  Add a single message to the chain.
  """
  def add_message(%{__struct__: LangChain.Chains.LLMChain} = chain, %Message{} = msg) do
    needs_response =
      cond do
        msg.role in [:user, :tool] -> true
        Message.is_tool_call?(msg) -> true
        msg.role in [:system, :assistant] -> false
        true -> false
      end

    %{
      chain
      | messages: chain.messages ++ [msg],
        last_message: msg,
        exchanged_messages: chain.exchanged_messages ++ [msg],
        needs_response: needs_response
    }
  end

  @doc """
  Add multiple messages to the chain.
  """
  def add_messages(%{__struct__: LangChain.Chains.LLMChain} = chain, messages) do
    Enum.reduce(messages, chain, fn msg, acc ->
      add_message(acc, msg)
    end)
  end

  @doc """
  Run the chain with the configured LLM.
  Returns {:ok, updated_chain} on success.
  """
  def run(%{__struct__: LangChain.Chains.LLMChain} = chain, _opts \\ []) do
    # Check if we have messages to send
    if chain.messages == [] do
      {:error, chain,
       LangChain.LangChainError.exception(
         type: "no_messages",
         message: "LLMChain cannot be run without messages"
       )}
    else
      # Generate a mock response as content parts (like real LLM)
      text = Process.get(:mock_llm_response) || random_response()
      content = [%LangChain.Message.ContentPart{type: :text, content: text}]

      response = %Message{
        role: :assistant,
        content: content,
        index: 0,
        status: :complete,
        tool_calls: [],
        tool_results: [],
        metadata: %{}
      }

      updated_chain = add_message(chain, response)

      {:ok, updated_chain}
    end
  end

  @doc """
  Set the mock response for the current process.
  """
  def set_response(content) do
    Process.put(:mock_llm_response, content)
  end

  @doc """
  Clear the mock response from the current process.
  """
  def clear_response do
    Process.delete(:mock_llm_response)
  end

  defp random_response do
    adjectives = ["bright", "clever", "swift", "wise", "keen", "sharp"]
    nouns = ["insight", "analysis", "thought", "idea", "perspective", "observation"]
    verbs = ["reveals", "shows", "demonstrates", "indicates", "suggests"]

    adj = Enum.random(adjectives)
    noun = Enum.random(nouns)
    verb = Enum.random(verbs)
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    "This #{adj} #{noun} #{verb} that the model is working correctly. #{id}"
  end
end
