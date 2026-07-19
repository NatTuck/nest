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
    * `{:set_crossed_thresholds, set}` — the ChatTurn
      appended a context-usage reminder to the messages
      list and wants the Agent to remember which threshold
      atoms (`:p25` / `:p50` / `:p75`) have already been
      announced so the next ChatTurn doesn't re-fire them.
      The set is cleared on successful compaction in
      `Compaction.ResultHandler.handle_success/3`, so
      warnings re-fire if usage rises again after a
      compaction.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Messages.Assistant
  alias Nest.Messages.Streaming

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

  def handle({:set_crossed_thresholds, set}, state) do
    set_crossed_thresholds(set, state)
  end

  # The ChatTurn finished its iteration normally. Clear
  # the chat_turn_pid (the supervisor's child is done),
  # the cancelled flag, the streaming_acc accumulator
  # (the message is in the list, the live partial is no
  # longer valid), and transition to :idle.
  #
  # If this agent has a parent (`clone_agent` spawned
  # it), forward a `:child_completed` cast so the parent
  # can merge our total usage into its `descendant_usage`,
  # forward `:clone_agent_result` to the blocked tool
  # worker, and broadcast its updated status.
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

    Broadcasts.status(state.name, state)

    case state.parent_name do
      nil ->
        {:noreply, state}

      parent_name ->
        notify_parent_on_idle(parent_name, state)
    end
  end

  # Cast our last assistant content + our total usage
  # (already inclusive of any grandchildren — see
  # `Broadcasts.total_usage/2`) up the tree. The parent's
  # `handle_cast({:child_completed, ...}, _)` merges the
  # usage and forwards `:clone_agent_result` to the tool
  # worker that's been blocked on our completion.
  #
  # We compute `total_usage` directly from the LLM metrics
  # in memory (`state.llm_metrics`) rather than
  # `GenServer.call(self(), :get_total_usage)` — the public
  # `get_total_usage/1` client API sends the request back
  # through the agent's mailbox, which would deadlock from
  # inside our own handler.
  defp notify_parent_on_idle(parent_name, state) do
    total_usage =
      Broadcasts.total_usage(
        state.llm_metrics.usage_totals,
        state.llm_metrics.descendant_usage
      )

    response = last_assistant_text(state)

    GenServer.cast(
      AgentsRegistry.via_tuple(parent_name),
      {:child_completed, state.name, response, total_usage}
    )

    {:noreply, state}
  end

  # Concatenate the text parts of the last assistant
  # message in `state.chat_state.messages`. Falls back to
  # an empty string for a child whose final turn produced
  # no text (e.g. only tool calls then a stopped-by-user).
  defp last_assistant_text(state) do
    case Enum.reverse(state.chat_state.messages) do
      [{:assistant, %{parts: parts}} | _] when is_list(parts) ->
        parts
        |> Enum.filter(&match?(%Nest.Messages.Part.Text{}, &1))
        |> Enum.map_join("", & &1.text)

      _ ->
        ""
    end
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

    Broadcasts.status(state.name, state)
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

    if benign_chat_crash?(exception) do
      # The HTTP worker caught a `GenServer.call` exit because
      # the target process stopped (test cleanup, supervisor
      # teardown). There is no real error to surface to the
      # user — the partial is already finalized above. Move
      # silently back to `:idle` without a `chat:error`
      # broadcast.
      state = %{state | chat_state: %{state.chat_state | status: :idle, chat_turn_pid: nil}}
      Broadcasts.status(state.name, state)
      {:noreply, state}
    else
      Logger.error(fn ->
        "[agent:#{state.name}] chat_crashed msg_index=#{state.chat_state.next_message_index} ::\n" <>
          Exception.format(:error, exception, stacktrace)
      end)

      Broadcasts.error(
        state.name,
        state.chat_state.next_message_index,
        error_msg,
        "ChatTurn.run_chat_task/1"
      )

      state = %{state | chat_state: %{state.chat_state | status: :idle, chat_turn_pid: nil}}
      Broadcasts.status(state.name, state)

      {:noreply, state}
    end
  end

  # The HTTP worker's `forward_crash` wraps the target
  # process's exit reason in a `%RuntimeError{message:
  # inspect(other)}` when the reason isn't already an
  # exception struct. Detect the wrapped `GenServer.call`
  # shutdowns (`{:normal, _}`, `{:noproc, _}`, `{:shutdown,
  # _}` nested under `{GenServer, :call, _}`) and treat
  # them as benign cleanups. Mirrors
  # `HTTPWorker.benign_exit?/2`.
  defp benign_chat_crash?(%RuntimeError{message: message}) do
    String.contains?(message, "{GenServer, :call,") and
      (String.contains?(message, ":normal,") or
         String.contains?(message, ":noproc,") or
         String.contains?(message, ":shutdown,"))
  end

  defp benign_chat_crash?(_), do: false

  # Persist the threshold set the ChatTurn just expanded.
  # Defensive: only accept `MapSet`s — the ChatTurn should
  # always send one, but a future bug that sends a list
  # shouldn't silently corrupt the field.
  defp set_crossed_thresholds(%MapSet{} = set, state) do
    state = %{state | chat_state: %{state.chat_state | crossed_thresholds: set}}
    {:noreply, state}
  end

  defp set_crossed_thresholds(_other, state), do: {:noreply, state}

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
        # Reuse the streaming module's `finalize/1` to assemble
        # parts in the order the events arrived. The accumulator's
        # `thinking_signature` is captured automatically.
        assistant = Streaming.finalize(acc)
        text_part = text_part_for_text_buffer(acc)
        thinking_part = thinking_part_for_thinking_buffer(acc)

        {:assistant,
         %Assistant{
           assistant
           | index: nil,
             timestamp: DateTime.utc_now(),
             parts: assemble_partial_parts(acc, text_part, thinking_part),
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
           parts: [],
           api_logs: pending_api_logs(state, index),
           metadata: %{"stopped_by_user" => true}
         }}
    end
  end

  # When the user stops the chat, finalize the streaming
  # accumulator as a normal assistant message. The accumulator's
  # `finalize/1` walks the segments to build the parts list in
  # order; we extend it here with any leftover buffer content
  # (defense in depth — the segments are the canonical source).
  defp assemble_partial_parts(acc, _text_part, _thinking_part) do
    Streaming.finalize(acc).parts
  end

  defp text_part_for_text_buffer(_acc), do: nil
  defp thinking_part_for_thinking_buffer(_acc), do: nil

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

  # Forwarded to the GenServer module which owns the
  # canonical implementation. The `__` prefix marks them
  # as internal.
  defp pending_api_logs(state, message_index) do
    Nest.Agents.Agent.__pending_api_logs__(state, message_index)
  end
end
