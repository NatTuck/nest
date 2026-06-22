defmodule Nest.Agents.Agent.Handlers.LLMStreamHandler do
  @moduledoc """
  `handle_info/2` handlers for LLM streaming events:
  `{:delta_received, _}`, `{:thinking_signature_received, _}`,
  `{:llm_error, _}`, `{:tool_calls_received, _}`,
  `{:tool_results_received, _}`,
  `{:llm_response_with_thinking, _, _}`, `{:llm_usage, _}`.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.Assistant
  alias Nest.Messages.Streaming
  alias Nest.Messages.Tool

  @doc """
  Dispatch a streaming message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:delta_received, content, part_type}, state) do
    delta_received(content, part_type, state)
  end

  def handle({:thinking_signature_received, sig}, state) do
    thinking_signature_received(sig, state)
  end

  def handle({:llm_error, error_msg}, state) do
    llm_error(error_msg, state)
  end

  def handle({:tool_calls_received, {:assistant, %Assistant{} = msg}}, state) do
    tool_calls_received(msg, state)
  end

  def handle({:tool_results_received, {:tool, %Tool{} = msg}}, state) do
    tool_results_received(msg, state)
  end

  def handle({:llm_response_with_thinking, _response, thinking}, state) do
    llm_response_with_thinking(thinking, state)
  end

  def handle({:llm_usage, usage}, state) do
    llm_usage(usage, state)
  end

  # Accumulate delta using Streaming module based on content type
  defp delta_received(delta_content, part_type, state) do
    acc = state.chat_state.streaming_acc

    new_acc =
      case part_type do
        :text -> Streaming.append_text(acc, delta_content)
        :thinking -> Streaming.append_thinking(acc, delta_content)
        # For unsupported types, append as text for now
        _ -> Streaming.append_text(acc, delta_content)
      end

    {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
  end

  # Anthropic's extended thinking emits a signature alongside the
  # thinking content. Stash it on the streaming accumulator so it
  # round-trips into the persisted assistant message's metadata.
  defp thinking_signature_received(signature, state) do
    new_acc = %{state.chat_state.streaming_acc | thinking_signature: signature}
    {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
  end

  # Finalize error message
  defp llm_error(error_msg, state) do
    error_message =
      {:assistant,
       %Assistant{
         index: state.chat_state.streaming_acc.index,
         timestamp: DateTime.utc_now(),
         content: error_msg,
         thinking: nil,
         tool_calls: nil,
         api_logs: pending_api_logs(state, state.chat_state.streaming_acc.index)
       }}

    messages = state.chat_state.messages ++ [error_message]
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
              clear_api_logs(state, state.chat_state.streaming_acc.index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.status(state.id, :idle)
    {:noreply, state}
  end

  defp tool_calls_received(tool_call_message, state) do
    index = tool_call_message.index
    pending_logs = pending_api_logs(state, index)

    tool_call_message =
      if pending_logs != [] do
        {:assistant,
         %{tool_call_message | api_logs: (tool_call_message.api_logs || []) ++ pending_logs}}
      else
        {:assistant, tool_call_message}
      end

    messages = state.chat_state.messages ++ [tool_call_message]
    Broadcasts.message(state.id, tool_call_message)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            next_message_index: state.chat_state.next_message_index + 1,
            pending_api_logs: clear_api_logs(state, index).chat_state.pending_api_logs,
            status: :executing_tools
        }
    }

    Broadcasts.status(state.id, :executing_tools)
    {:noreply, state}
  end

  defp tool_results_received(tool_result_message, state) do
    index = tool_result_message.index
    pending_logs = pending_api_logs(state, index)

    tool_result_message =
      if pending_logs != [] do
        {:tool,
         %{tool_result_message | api_logs: (tool_result_message.api_logs || []) ++ pending_logs}}
      else
        {:tool, tool_result_message}
      end

    messages = state.chat_state.messages ++ [tool_result_message]
    Broadcasts.message(state.id, tool_result_message)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            next_message_index: state.chat_state.next_message_index + 1,
            pending_api_logs: clear_api_logs(state, index).chat_state.pending_api_logs,
            status: :streaming,
            streaming_acc: Streaming.new(state.chat_state.next_message_index + 1)
        }
    }

    Broadcasts.status(state.id, :streaming)
    {:noreply, state}
  end

  # Finalize assistant message with thinking using Streaming.finalize
  defp llm_response_with_thinking(thinking, state) do
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
         api_logs: pending_api_logs(state, state.chat_state.streaming_acc.index)
       }}

    messages = state.chat_state.messages ++ [final_message]
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
              clear_api_logs(state, state.chat_state.streaming_acc.index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.status(state.id, :idle)
    {:noreply, state}
  end

  defp llm_usage(usage, state) do
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

  # Forwarded to the GenServer module which owns the canonical
  # implementation. The `__` prefix marks them as internal.
  defp pending_api_logs(state, message_index) do
    Nest.Agents.Agent.__pending_api_logs__(state, message_index)
  end

  defp clear_api_logs(state, message_index) do
    Nest.Agents.Agent.__clear_pending_api_logs__(state, message_index)
  end
end
