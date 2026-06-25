defmodule Nest.Agents.Agent.Handlers.ChatTurnHandler do
  @moduledoc """
  `handle_info/2` handlers for the ChatTurn's lifecycle
  events. The ChatTurn is the iteration driver; the Agent
  receives these events to update its own state and
  broadcast to the UI.

  Events handled:

    * `{:chat_idle, _chat_turn_pid}` — the ChatTurn
      finished its iteration normally. Clear the
      `chat_turn_pid`, the `cancelled` flag, and the
      `streaming_acc` accumulator (the assistant message is
      in the list, the live partial is no longer valid),
      and transition to `:idle`.
    * `{:chat_stopped, _chat_turn_pid}` — the user clicked
      Stop. The ChatTurn killed the active worker and is
      winding down. Finalize the partial
      `Streaming.AssistantAccumulator` (if any) as an
      assistant message tagged with `metadata.stopped_by_user:
      true`, transition to `:idle`, and clear bookkeeping.
    * `{:chat_crashed, exception, stacktrace}` — the HTTP
      worker raised an unhandled exception. Finalize the
      partial, broadcast `chat:error` (with the
      `[Source: ...]` tag for log correlation), log the
      full stacktrace server-side, and transition to
      `:idle`.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.Assistant
  alias Nest.Messages.Streaming
  alias Nest.Messages.ToolCall

  require Logger

  @doc """
  Dispatch a ChatTurn lifecycle message. Returns the
  GenServer's reply tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:chat_idle, _chat_turn_pid}, state) do
    chat_idle(state)
  end

  def handle({:chat_stopped, _chat_turn_pid}, state) do
    chat_stopped(state)
  end

  def handle({:chat_crashed, exception, stacktrace}, state) do
    chat_crashed(exception, stacktrace, state)
  end

  # The ChatTurn finished its iteration normally. Clear
  # the chat_turn_pid (the supervisor's child is done),
  # the cancelled flag, the streaming_acc accumulator
  # (the message is in the list, the live partial is no
  # longer valid), and transition to :idle.
  defp chat_idle(state) do
    state = %{
      state
      | chat_state: %{
          state.chat_state
          | status: :idle,
            streaming_acc: nil,
            chat_turn_pid: nil,
            cancelled: false
        }
    }

    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  # The user clicked Stop. The ChatTurn killed the active
  # worker and is winding down. Finalize the streaming
  # accumulator (if any) as an assistant message tagged
  # with `metadata.stopped_by_user: true`, transition to
  # :idle, and clear bookkeeping.
  #
  # If the streaming_acc accumulator is `nil` (no deltas
  # arrived before the stop), we still append a placeholder
  # message with `content: nil` and `metadata.stopped_by_user: true`
  # so the message list is consistent — the user clicked
  # Stop, so the assistant turn exists, just empty.
  defp chat_stopped(state) do
    state = finalize_partial_if_any(state)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | status: :idle,
            chat_turn_pid: nil,
            cancelled: false
        }
    }

    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  # The HTTP worker raised an unhandled exception
  # (typically a `FunctionClauseError` because the
  # provider sent an unrecognized delta shape). The
  # ChatTurn caught it and forwarded the exception +
  # stacktrace here.
  #
  # UX: save whatever was streamed before the crash as a
  # normal assistant message (so the user doesn't lose
  # their work), then broadcast a `chat:error` and
  # transition to idle. The frontend's `chat:error`
  # handler shows the error in the StatusBanner and
  # clears the partial.
  #
  # The exception + stacktrace is formatted server-side
  # so the user-facing message carries the file/line of
  # the crash — useful when debugging a `protocol
  # Enumerable ... Got value: nil` from deep in the
  # call chain.
  defp chat_crashed(exception, stacktrace, state) do
    state = finalize_partial_if_any(state)

    error_msg = format_chat_task_error(exception, stacktrace)

    Logger.error(fn ->
      "[agent:#{state.id}] chat_crashed msg_index=#{state.chat_state.next_message_index} ::\n" <>
        Exception.format(:error, exception, stacktrace)
    end)

    Broadcasts.error(
      state.id,
      state.chat_state.next_message_index,
      error_msg,
      "ChatTurn.run_chat_task/1"
    )

    state = %{state | chat_state: %{state.chat_state | status: :idle, chat_turn_pid: nil}}
    Broadcasts.status(state.id, state)

    {:noreply, state}
  end

  # Finalize the streaming_acc accumulator (Agent-side)
  # into a normal assistant message and append it via the
  # canonical path. Returns the new state.
  #
  # Always appends a message — even if the streaming_acc
  # accumulator is `nil` (no deltas arrived) or empty
  # (zero text/thinking).
  # The user clicked Stop during a turn, so the assistant
  # turn exists; we just record it as empty. The message
  # carries `metadata.stopped_by_user: true` so the UI
  # can render a "stopped" indicator.
  defp finalize_partial_if_any(state) do
    final_message = build_partial_assistant_message(state)
    {_stamped, state} = Nest.Agents.Agent.__append_message__(state, final_message)
    %{state | chat_state: %{state.chat_state | streaming_acc: nil}}
  end

  defp build_partial_assistant_message(state) do
    case state.chat_state.streaming_acc do
      %Streaming.AssistantAccumulator{} = acc ->
        {:assistant,
         %Assistant{
           index: nil,
           timestamp: DateTime.utc_now(),
           content:
             if(acc.text_buffer == [],
               do: nil,
               else: IO.iodata_to_binary(acc.text_buffer)
             ),
           thinking:
             if(acc.thinking_buffer == [],
               do: nil,
               else: IO.iodata_to_binary(acc.thinking_buffer)
             ),
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
           api_logs: pending_api_logs(state, acc.index),
           metadata: %{"stopped_by_user" => true}
         }}

      nil ->
        # No accumulator (stop arrived between turns, or
        # before the first delta). Build a placeholder so
        # the message list is consistent.
        index = state.chat_state.active_message_index

        {:assistant,
         %Assistant{
           index: nil,
           timestamp: DateTime.utc_now(),
           content: nil,
           thinking: nil,
           tool_calls: nil,
           api_logs: pending_api_logs(state, index),
           metadata: %{"stopped_by_user" => true}
         }}
    end
  end

  # Build the user-facing error message. We lead with
  # the exception's message (the part the user is most
  # likely to recognize — e.g. "protocol Enumerable not
  # implemented for Atom. ... Got value: nil") and then
  # append a 5-frame stacktrace snippet so the UI shows
  # where the crash happened. The full stacktrace is in
  # the server log (logged by both the chat task and
  # this handler).
  @stacktrace_snippet_frames 5
  @stacktrace_snippet_max_bytes 2000

  defp format_chat_task_error(exception, stacktrace) do
    formatted = Exception.format(:error, exception, stacktrace)

    # `Exception.format/3` returns the message + the full
    # stacktrace. Trim to the top N frames so the UI gets
    # a useful pin without a 50-line scroll. The full
    # formatted text is in the server log; we cap the
    # user-facing snippet to ~2 KB as a safety net.
    snippet = take_stacktrace_frames(formatted, @stacktrace_snippet_frames)
    truncate_string(snippet, @stacktrace_snippet_max_bytes)
  end

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

  defp parse_tool_args(buffer) when is_binary(buffer) and buffer != "" do
    case Jason.decode(buffer) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  # `arguments_buffer` is now an IO list (see
  # `Streaming.PartialToolCall`); convert to a binary before
  # `Jason.decode`.
  defp parse_tool_args(buffer) when is_list(buffer) and buffer != [] do
    buffer |> Enum.reverse() |> IO.iodata_to_binary() |> parse_tool_args()
  end

  defp parse_tool_args(_), do: nil

  # Forwarded to the GenServer module which owns the
  # canonical implementation. The `__` prefix marks them
  # as internal.
  defp pending_api_logs(state, message_index) do
    Nest.Agents.Agent.__pending_api_logs__(state, message_index)
  end
end
