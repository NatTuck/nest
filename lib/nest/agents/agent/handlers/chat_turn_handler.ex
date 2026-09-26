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
      compaction. Rebuilt from persisted notice metadata on
      restore (`Init.seed_from_db/3`).
    * `{:set_context_projection, tokens}` — the forward-looking
      context size the reminder compared against; stored on
      `live.context_projection` and surfaced on the status
      payload for the UI chip.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.LLM.Client
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

  # Bounded Stop safety net. The Agent scheduled this when the user hit
  # Stop; if the ChatTurn hasn't reported back by now it is dead or
  # wedged, so force the agent back to idle.
  def handle({:stop_fallback, chat_turn_pid}, state) do
    stop_fallback(chat_turn_pid, state)
  end

  # The Agent monitors its ChatTurn. A DOWN while that turn is still the
  # active one means it died without reporting — force idle so the user
  # is never stuck behind a dead turn.
  def handle({:DOWN, _ref, :process, pid, reason}, state) do
    chat_turn_down(pid, reason, state)
  end

  def handle({:set_context_projection, tokens}, state) do
    set_context_projection(tokens, state)
  end

  # The ChatTurn finished its iteration normally. Clear
  # the chat_turn_pid (the supervisor's child is done),
  # the cancelled flag, the streaming_acc accumulator
  # (the message is in the list, the live partial is no
  # longer valid), and transition to :idle.
  #
  # If this agent has a parent (an `agents-spawn` with
  # `clone_context` spawned it), forward a `:child_completed`
  # cast so the parent can merge our total usage into its
  # `descendant_usage`, forward `:spawn_agent_result` to the
  # blocked tool worker, and broadcast its updated status.
  defp chat_idle(state) do
    state = %{
      state
      | live: %{
          state.live
          | status: :idle,
            streaming_acc: nil,
            chat_turn_pid: nil,
            cancelled: false,
            tool_index_map: %{},
            # The turn is over; any forward-looking context projection
            # the reminder computed is no longer meaningful.
            context_projection: nil
        }
    }

    Broadcasts.status(state)

    case state.tree_position.parent_name do
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
  # usage and forwards `:spawn_agent_result` to the tool
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
      AgentsRegistry.via_tuple(state.space_id, parent_name),
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
        Client.text_from_parts(parts)

      _ ->
        ""
    end
  end

  # The user clicked Stop. The ChatTurn killed the active
  # worker and is winding down. First, stop any outstanding
  # queries the agent was running (only `pending_children` —
  # idle specialists are left running). Then finalize
  # the streaming accumulator (if any) as an assistant
  # message tagged with `metadata.stopped_by_user: true`,
  # transition to :idle, and clear bookkeeping.
  #
  # If the streaming_acc accumulator is `nil` (no deltas
  # arrived before the stop), we still append a placeholder
  # message with `content: nil` and `metadata.stopped_by_user: true`
  # so the message list is consistent — the user clicked
  # Stop, so the assistant turn exists, just empty.
  defp chat_stopped(state), do: {:noreply, force_idle(state)}

  # Force the agent back to `:idle` from any busy state. Always stops any
  # pending child queries (the cascade is meaningful even when the agent
  # itself is already idle — e.g. a `chat_stopped` that arrives between
  # turns). The partial finalize/broadcast is idempotent: a no-op when
  # the agent is already idle with no in-flight turn, so the healthy
  # `:chat_stopped` cast and the bounded `:stop_fallback` can race
  # without double-finalizing.
  @doc false
  @spec force_idle(Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def force_idle(state) do
    state = SubAgent.stop_pending_children(state)

    if state.live.status == :idle and is_nil(state.live.chat_turn_pid) and
         is_nil(state.live.streaming_acc) do
      state
    else
      finalize_stopped(state)
    end
  end

  defp finalize_stopped(state) do
    state = finalize_partial_if_any(state)

    state = %{
      state
      | live: %{
          state.live
          | status: :idle,
            chat_turn_pid: nil,
            cancelled: false
        }
    }

    Broadcasts.status(state)
    notify_parent_of_failure(state, :stopped)
    state
  end

  # Called after `@stop_fallback_ms` when the user stopped. Kill a
  # still-alive ChatTurn (it never acked) and force idle. Stale tokens
  # (a new turn started, or the turn already finalized) no-op.
  defp stop_fallback(chat_turn_pid, state) do
    if state.live.chat_turn_pid == chat_turn_pid and busy?(state.live.status) do
      if is_pid(chat_turn_pid) and Process.alive?(chat_turn_pid) do
        Process.exit(chat_turn_pid, :kill)
      end

      {:noreply, force_idle(state)}
    else
      {:noreply, state}
    end
  end

  # The monitored ChatTurn process died. If it is still the active turn,
  # it exited without reporting (crash), so finalize the partial and
  # move to idle. An orderly shutdown reason (`:normal` / `:shutdown`) is
  # silent; anything else is surfaced as a `chat:error`.
  defp chat_turn_down(pid, reason, state) do
    if state.live.chat_turn_pid == pid do
      state = finalize_partial_if_any(state)

      state = %{
        state
        | live: %{
            state.live
            | status: :idle,
              chat_turn_pid: nil,
              cancelled: false,
              tool_index_map: %{}
          }
      }

      if benign_chat_turn_down?(reason) do
        Broadcasts.status(state)
      else
        Logger.error("[agent:#{state.name}] ChatTurn exited unexpectedly: #{inspect(reason)}")

        Broadcasts.error(
          state.space_id,
          state.name,
          state.chat_state.next_message_index,
          "The agent's chat process stopped unexpectedly (#{inspect(reason)}).",
          "ChatTurn"
        )

        Broadcasts.status(state)
      end

      notify_parent_of_failure(state, {:crashed, inspect(reason)})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp benign_chat_turn_down?(:normal), do: true
  defp benign_chat_turn_down?(:shutdown), do: true
  defp benign_chat_turn_down?({:shutdown, _}), do: true
  defp benign_chat_turn_down?(_), do: false

  # A chat turn is in flight for these statuses. Anything else
  # (`:idle`, `:model_missing`, `:context_overflow`, ...) is terminal.
  @busy_statuses [:streaming, :executing_tools, :compacting]
  defp busy?(status), do: status in @busy_statuses

  @doc """
  The ChatTurn supervisor refused to start a turn (saturated). The
  caller has already set `:streaming` and broadcast it, so force idle
  and surface an error rather than leaving the agent wedged.
  """
  @spec spawn_failed(Nest.Agents.Agent.t(), String.t()) :: Nest.Agents.Agent.t()
  def spawn_failed(state, reason) do
    state = force_idle(state)

    Broadcasts.error(
      state.space_id,
      state.name,
      state.chat_state.next_message_index,
      "Could not start chat turn: #{reason}",
      "ChatTurnSpawner.spawn/4"
    )

    state
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
      state = %{state | live: %{state.live | status: :idle, chat_turn_pid: nil}}
      Broadcasts.status(state)
      notify_parent_of_failure(state, crash_reason(exception))
      {:noreply, state}
    else
      Logger.error(fn ->
        "[agent:#{state.name}] chat_crashed msg_index=#{state.chat_state.next_message_index} ::\n" <>
          Exception.format(:error, exception, stacktrace)
      end)

      Broadcasts.error(
        state.space_id,
        state.name,
        state.chat_state.next_message_index,
        error_msg,
        "ChatTurn.run_chat_task/1"
      )

      state = %{state | live: %{state.live | status: :idle, chat_turn_pid: nil}}
      Broadcasts.status(state)
      notify_parent_of_failure(state, crash_reason(exception))

      {:noreply, state}
    end
  end

  # Cast a `:child_failed` notification to the parent when this agent
  # ends a turn *without* a normal completion (crash or user Stop). The
  # parent then fails the matching `pending_children` slot immediately
  # (its worker may be blocked on an `agents-spawn` / `agents-batch`),
  # instead of waiting for the per-item timeout. Roots (no
  # `parent_name`) skip the notification.
  defp notify_parent_of_failure(state, reason) do
    case state.tree_position.parent_name do
      nil ->
        :ok

      parent_name ->
        GenServer.cast(
          AgentsRegistry.via_tuple(state.space_id, parent_name),
          {:child_failed, state.name, reason}
        )
    end
  end

  # A compact, inspect-safe failure reason for the parent's tool
  # result. `exception` may be a real exception struct or an atom like
  # `:saturated`, so guard `Exception.message/1`.
  defp crash_reason(%{__exception__: true} = exception),
    do: {:crashed, Exception.message(exception)}

  defp crash_reason(other), do: {:crashed, inspect(other)}

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

  # Record the threshold set the ChatTurn just expanded. The set is
  # remembered in memory and rebuilt from persisted notice metadata on
  # restore (see `Init.seed_from_db/3`).
  # Defensive: only accept `MapSet`s — the ChatTurn should
  # always send one, but a future bug that sends a list
  # shouldn't silently corrupt the field.
  defp set_crossed_thresholds(%MapSet{} = set, state) do
    state = %{state | live: %{state.live | crossed_thresholds: set}}
    {:noreply, state}
  end

  defp set_crossed_thresholds(_other, state), do: {:noreply, state}

  # Store the forward-looking context size the reminder compared
  # against so the status payload can surface it to the UI
  # (`usage.projected_context_input_tokens`).
  defp set_context_projection(tokens, state) when is_integer(tokens) and tokens >= 0 do
    state = %{state | live: %{state.live | context_projection: tokens}}
    # Surface it now: the value is cleared when the turn goes idle, so
    # without a broadcast here the UI might never receive it.
    Broadcasts.status(state)
    {:noreply, state}
  end

  defp set_context_projection(_other, state), do: {:noreply, state}

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
    final_message =
      Streaming.partial_message(state.live.streaming_acc, %{"stopped_by_user" => true})

    {_stamped, state} = Nest.Agents.Agent.__append_message__(state, final_message)
    %{state | live: %{state.live | streaming_acc: nil, tool_index_map: %{}}}
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
end
