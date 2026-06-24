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
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall

  require Logger

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

  def handle({:chat_task_crashed, exception, stacktrace}, state) do
    chat_task_crashed(exception, stacktrace, state)
  end

  # Backward-compat: legacy 2-tuple form. Some tests / call
  # sites still send `{:chat_task_crashed, message_string}`.
  # The handler wraps the string in a RuntimeError so the
  # formatter still produces a stacktrace-shaped message.
  def handle({:chat_task_crashed, error_msg}, state) when is_binary(error_msg) do
    chat_task_crashed(error_msg, state)
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

  def handle({:system_reminder_received, {:system, %System{} = reminder}}, state) do
    system_reminder_received(reminder, state)
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
    error_index = state.chat_state.streaming_acc.index

    error_message =
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         content: error_msg,
         thinking: nil,
         tool_calls: nil,
         api_logs: pending_api_logs(state, error_index)
       }}

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, error_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | streaming_acc: nil,
            active_message_index: stamped_index,
            pending_api_logs: clear_api_logs(state, stamped_index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  # The chat task itself crashed (an unhandled raise in the LLM
  # client — typically a `FunctionClauseError` because the
  # provider sent an unrecognized delta shape, or a
  # `Protocol.UndefinedError` for `Enumerable` on `nil` from a
  # missing field in a message struct). The chat task's
  # try/catch in `ChatPipeline.run_chat_task_and_notify/3`
  # converted the raise into a `{:chat_task_crashed, exception,
  # stacktrace}` message so the agent could recover; this
  # handler is the recovery side.
  #
  # UX: save whatever was streamed before the crash as a normal
  # assistant message (so the user doesn't lose their work),
  # then broadcast a `chat:error` and transition to idle. The
  # frontend's `chat:error` handler (`assets/js/channels.js`)
  # shows the error in the StatusBanner and clears the partial.
  #
  # The exception + stacktrace is formatted server-side so the
  # user-facing message carries the file/line of the crash —
  # useful when debugging a `protocol Enumerable ... Got value:
  # nil` from deep in the call chain.
  defp chat_task_crashed(exception, stacktrace, state) do
    error_msg = format_chat_task_error(exception, stacktrace)

    # Always log the full stacktrace at error level on the
    # server. The chat task itself already logged the full
    # `Exception.format/3` output (see `ChatPipeline`), but
    # logging again here gives a second log entry tagged with
    # the agent id and message index, so we can grep by
    # agent even when the chat task's log line is buried
    # in another agent's output.
    Logger.error(fn ->
      "[agent:#{state.id}] chat_task_crashed msg_index=#{state.chat_state.next_message_index} ::\n" <>
        Exception.format(:error, exception, stacktrace)
    end)

    state =
      case has_partial_content?(state.chat_state.streaming_acc) do
        true ->
          # Save the partial as a normal assistant message.
          finalize_partial(state)

        false ->
          # No content was streamed before the crash. Just
          # drop the accumulator and transition to idle.
          clear_streaming_acc(state)
      end

    # Broadcast the error. The frontend's `chat:error` handler
    # shows the error banner and clears the partial.
    # `Broadcasts.error/4` is the centralized error path: it
    # logs the failure and tags the user-facing message with
    # `[Source: ...]` so we can find the server log entry from
    # the UI's error text.
    Broadcasts.error(
      state.id,
      state.chat_state.next_message_index,
      error_msg,
      "LLMStreamHandler.chat_task_crashed/2"
    )

    state = %{state | chat_state: %{state.chat_state | status: :idle}}
    Broadcasts.status(state.id, state)

    {:noreply, state}
  end

  # Backward-compat: callers (e.g. legacy code paths) that
  # only have the message string, not the full exception.
  # Wraps it in a `RuntimeError` so the formatted output still
  # includes a stacktrace frame.
  defp chat_task_crashed(error_msg, state) when is_binary(error_msg) do
    chat_task_crashed(%RuntimeError{message: error_msg}, [], state)
  end

  # Build the user-facing error message. We lead with the
  # exception's message (the part the user is most likely to
  # recognize — e.g. "protocol Enumerable not implemented for
  # Atom. ... Got value: nil") and then append a 5-frame
  # stacktrace snippet so the UI shows where the crash
  # happened. The full stacktrace is in the server log
  # (logged by both the chat task and this handler).
  @stacktrace_snippet_frames 5
  @stacktrace_snippet_max_bytes 2000

  defp format_chat_task_error(exception, stacktrace) do
    formatted = Exception.format(:error, exception, stacktrace)

    # `Exception.format/3` returns the message + the full
    # stacktrace. Trim to the top N frames so the UI gets a
    # useful pin without a 50-line scroll. The full
    # formatted text is in the server log; we cap the
    # user-facing snippet to ~2 KB as a safety net.
    snippet = take_stacktrace_frames(formatted, @stacktrace_snippet_frames)
    truncate_string(snippet, @stacktrace_snippet_max_bytes)
  end

  # Pull the first N stack frames out of an
  # `Exception.format/3` string. The format puts a header line
  # (e.g. "(protocol_undefined) ...") then each frame on its
  # own line, indented. We keep the header and the first
  # `N` indented frame lines.
  defp take_stacktrace_frames(formatted, n) do
    lines = String.split(formatted, "\n")

    {header, frames} =
      Enum.split_while(lines, fn line ->
        not String.starts_with?(line, "    ")
      end)

    Enum.take(frames, n)
    |> Kernel.++(if(length(frames) > n, do: ["    ..."], else: []))
    |> Enum.concat(header)
    |> Enum.join("\n")
  end

  defp truncate_string(s, max) when byte_size(s) <= max, do: s

  defp truncate_string(s, max) do
    binary_part(s, 0, max) <> "\n...(truncated)"
  end

  defp has_partial_content?(%Streaming.AssistantAccumulator{
         text_buffer: text,
         thinking_buffer: thinking
       }),
       do: text != "" or thinking != ""

  defp has_partial_content?(_), do: false

  # Finalize the streaming accumulator into a normal assistant
  # message and append it to the messages list. Mirrors
  # `llm_response_with_thinking/2` but with no `thinking`
  # argument (the partial already has its thinking) and no
  # `stopped_by_user` flag (this is a crash, not a stop).
  defp finalize_partial(state) do
    acc = state.chat_state.streaming_acc

    final_message =
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         content: acc.text_buffer,
         thinking: if(acc.thinking_buffer == "", do: nil, else: acc.thinking_buffer),
         thinking_signature: acc.thinking_signature,
         tool_calls:
           acc.tool_calls
           |> Map.values()
           |> Enum.filter(& &1.complete?)
           |> Enum.map(fn partial ->
             %ToolCall{
               id: partial.id,
               name: partial.name,
               arguments: parse_tool_args(partial.arguments_buffer)
             }
           end),
         api_logs: pending_api_logs(state, acc.index)
       }}

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, final_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    %{
      state
      | chat_state: %{
          state.chat_state
          | streaming_acc: nil,
            active_message_index: stamped_index,
            pending_api_logs: clear_api_logs(state, stamped_index).chat_state.pending_api_logs
        }
    }
  end

  defp clear_streaming_acc(state) do
    %{state | chat_state: %{state.chat_state | streaming_acc: nil}}
  end

  # Parse a tool-call arguments buffer as JSON. Falls back to
  # `nil` if the buffer is empty or unparseable; the consumer
  # can decide how to render an incomplete tool call.
  defp parse_tool_args(buffer) when is_binary(buffer) and buffer != "" do
    case Jason.decode(buffer) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp parse_tool_args(_), do: nil

  defp tool_calls_received(tool_call_message, state) do
    pending_logs = pending_api_logs(state, tool_call_message.index)

    tool_call_message =
      if pending_logs != [] do
        {:assistant,
         %{
           tool_call_message
           | api_logs: (tool_call_message.api_logs || []) ++ pending_logs,
             index: nil
         }}
      else
        {:assistant, %{tool_call_message | index: nil}}
      end

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, tool_call_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs: clear_api_logs(state, stamped_index).chat_state.pending_api_logs,
            status: :executing_tools
        }
    }

    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  defp tool_results_received(tool_result_message, state) do
    pending_logs = pending_api_logs(state, tool_result_message.index)

    tool_result_message =
      if pending_logs != [] do
        {:tool,
         %{
           tool_result_message
           | api_logs: (tool_result_message.api_logs || []) ++ pending_logs,
             index: nil
         }}
      else
        {:tool, %{tool_result_message | index: nil}}
      end

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, tool_result_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs: clear_api_logs(state, stamped_index).chat_state.pending_api_logs,
            status: :streaming,
            streaming_acc: Streaming.new(stamped_index + 1)
        }
    }

    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  # Finalize assistant message with thinking using Streaming.finalize
  defp llm_response_with_thinking(thinking, state) do
    acc = state.chat_state.streaming_acc
    assistant = Streaming.finalize(acc)

    final_message =
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         content: assistant.content,
         thinking: thinking,
         # Anthropic's extended-thinking signature, echoed back on
         # subsequent turns. The AnthropicClient reads this field
         # directly when rebuilding the assistant content block
         # array for the next request.
         thinking_signature: acc.thinking_signature,
         tool_calls: assistant.tool_calls,
         api_logs: pending_api_logs(state, acc.index)
       }}

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, final_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | streaming_acc: nil,
            active_message_index: stamped_index,
            pending_api_logs: clear_api_logs(state, stamped_index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.status(state.id, state)
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

  # A late system reminder was injected into the LLM-bound messages
  # list by `LLMRunner.maybe_inject_budget_warning/3`. We persist it
  # to `state.chat_state.messages` (for transparency and to keep the
  # GenServer's view of the conversation consistent with what the
  # LLM saw) and broadcast it as a regular `chat:message` event so
  # the UI can render it.
  #
  # Stale reminders (from a previous turn that was near the cap)
  # stay in the message list. We accept this as the cost of
  # transparency — see `notes/normalize-system-messages.md`.
  defp system_reminder_received(reminder, state) do
    {_, state} = Nest.Agents.Agent.__append_message__(state, {:system, %{reminder | index: nil}})
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
