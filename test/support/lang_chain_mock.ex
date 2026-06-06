defmodule Nest.LangChainMock do
  @moduledoc """
  Complete mock implementation of LangChain.Chains.LLMChain for testing.

  This mock implements all the functions needed by the application without
  delegating to the original module, avoiding unexpected side effects.

  Uses Agent for process-safe state storage since LLM calls happen in separate Tasks.
  """

  alias LangChain.Message
  alias LangChain.Message.ContentPart

  # Agent name for global state storage
  @agent_name :lang_chain_mock_agent

  @doc """
  Starts the mock agent for state storage.
  Call this in test setup when using tool responses.
  """
  def start_mock_agent do
    case Agent.start(fn -> %{response: nil, tool_response: nil} end, name: @agent_name) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Stops the mock agent.
  """
  def stop_mock_agent do
    case Process.whereis(@agent_name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

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
  Add tools to the chain.
  """
  def add_tools(%{__struct__: LangChain.Chains.LLMChain} = chain, tools) do
    tool_map =
      Enum.reduce(tools, %{}, fn tool, acc ->
        Map.put(acc, tool.name, tool)
      end)

    %{
      chain
      | tools: chain.tools ++ tools,
        _tool_map: tool_map
    }
  end

  @doc """
  Run the chain with the configured LLM.
  Returns {:ok, updated_chain} on success.
  """
  def run(%{__struct__: LangChain.Chains.LLMChain} = chain, opts \\ []) do
    # Check if we have messages to send
    if chain.messages == [] do
      {:error, chain,
       LangChain.LangChainError.exception(
         type: "no_messages",
         message: "LLMChain cannot be run without messages"
       )}
    else
      # Get mock configuration from Agent (process-safe)
      mock_config = get_mock_config()
      tool_response = mock_config[:tool_response]

      response =
        if tool_response do
          # Return the tool response and clear it so next call returns normal text
          clear_tool_response()
          build_tool_call_response(tool_response)
        else
          # Generate a mock response as content parts (like real LLM)
          text = mock_config[:response] || random_response()
          content = [%LangChain.Message.ContentPart{type: :text, content: text}]

          %Message{
            role: :assistant,
            content: content,
            index: 0,
            status: :complete,
            tool_calls: [],
            tool_results: [],
            metadata: %{}
          }
        end

      updated_chain = add_message(chain, response)

      # For backwards compatibility: also handle :while_needs_response mode
      mode = opts[:mode] || :until_success

      if mode == :while_needs_response and response.tool_calls != [] do
        # Simulate tool execution by adding tool results to the chain
        tool_results = build_tool_results(response.tool_calls)

        tool_result_message = %Message{
          role: :tool,
          content: tool_results,
          index: length(chain.messages) + 1,
          status: :complete,
          tool_calls: [],
          tool_results: tool_results,
          metadata: %{}
        }

        updated_chain = add_message(updated_chain, tool_result_message)

        # Generate final response after tool execution
        final_text = mock_config[:response] || "Tool execution completed successfully."
        final_content = [%LangChain.Message.ContentPart{type: :text, content: final_text}]

        final_response = %Message{
          role: :assistant,
          content: final_content,
          index: length(updated_chain.messages),
          status: :complete,
          tool_calls: [],
          tool_results: [],
          metadata: %{}
        }

        updated_chain = add_message(updated_chain, final_response)

        {:ok, updated_chain}
      else
        {:ok, updated_chain}
      end
    end
  end

  defp get_mock_config do
    case Process.whereis(@agent_name) do
      nil -> %{response: nil, tool_response: nil}
      _pid -> Agent.get(@agent_name, & &1)
    end
  end

  defp clear_tool_response do
    case Process.whereis(@agent_name) do
      nil -> :ok
      _pid -> Agent.update(@agent_name, &%{&1 | tool_response: nil})
    end
  end

  defp build_tool_call_response(%{tool_calls: tool_calls, text: text}) do
    content = [%LangChain.Message.ContentPart{type: :text, content: text}]

    %Message{
      role: :assistant,
      content: content,
      index: 0,
      status: :complete,
      tool_calls: tool_calls,
      tool_results: [],
      metadata: %{}
    }
  end

  defp build_tool_results(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %LangChain.Message.ToolResult{
        tool_call_id: tc.call_id,
        name: tc.name,
        content: "Mock tool result for #{tc.name}",
        is_error: false
      }
    end)
  end

  @doc """
  Set the mock response for the current process.
  """
  def set_response(content) do
    case Process.whereis(@agent_name) do
      nil -> start_mock_agent()
      _pid -> :ok
    end

    Agent.update(@agent_name, &%{&1 | response: content})
  end

  @doc """
  Set a tool call response for testing tool execution flow.

  ## Example

      Nest.LangChainMock.set_tool_response(%{
        text: "I'll run that command for you",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_123",
            name: "shell_cmd",
            arguments: %{"command" => "ls -la"}
          }
        ]
      })
  """
  def set_tool_response(%{tool_calls: _tool_calls, text: _text} = response) do
    case Process.whereis(@agent_name) do
      nil -> start_mock_agent()
      _pid -> :ok
    end

    Agent.update(@agent_name, &%{&1 | tool_response: response})
  end

  @doc """
  Clear the mock response from the current process.
  """
  def clear_response do
    case Process.whereis(@agent_name) do
      nil -> :ok
      _pid -> Agent.update(@agent_name, fn _ -> %{response: nil, tool_response: nil} end)
    end
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

  @doc """
  Execute tool calls in the chain (mock implementation).
  Simulates tool execution by creating tool results.
  """
  def execute_tool_calls(%{__struct__: LangChain.Chains.LLMChain} = chain, _opts \\ []) do
    # Get the last message which should contain tool calls
    last_message = chain.last_message

    if last_message && last_message.tool_calls != [] do
      # Generate mock tool results for each tool call
      tool_results =
        Enum.map(last_message.tool_calls, fn tc ->
          %LangChain.Message.ToolResult{
            tool_call_id: tc.call_id,
            name: tc.name,
            content: "Mock output for #{tc.name}",
            is_error: false
          }
        end)

      # Create a tool result message
      tool_content = Enum.map_join(tool_results, "\n", fn tr -> tr.content end)

      tool_result_msg = %Message{
        role: :tool,
        content: [ContentPart.text!(tool_content)],
        index: length(chain.messages),
        status: :complete,
        tool_calls: [],
        tool_results: tool_results,
        metadata: %{}
      }

      # Add the tool result message to the chain
      add_message(chain, tool_result_msg)
    else
      chain
    end
  end

  @doc """
  Execute a single step in the chain (mock implementation).
  """
  def execute_step(%{__struct__: LangChain.Chains.LLMChain} = chain, _opts \\ []) do
    # Just return the chain unchanged for the mock
    {:ok, chain}
  end
end
