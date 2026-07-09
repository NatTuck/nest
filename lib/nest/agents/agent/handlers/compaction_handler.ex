defmodule Nest.Agents.Agent.Handlers.CompactionHandler do
  @moduledoc """
  `handle_info/2` handlers for compaction-related events:
  `{:compaction_done, _, _}`, `{:compaction_failed, _, _}`,
  `{:task_compaction_request, _, _}`, `{:task_compaction_done, _, _}`,
  `{:task_compaction_failed, _, _}`,
  `{:needs_compaction, _, _, _}`, `:retry_compaction`,
  `:compaction_loop_detected_ok`.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.

  Per-iteration preflight compaction has been removed; the
  BatchSizer handles tool-result sizing instead. See
  `notes/extract-compaction-and-resumable-chat-turn.md` for the
  design.

  The `regenerate_for_compaction/2` helper that rebuilds the
  agent's `state.chat_state.messages[0]` (the system prompt)
  from the latest DB state before every compaction lives in
  `Nest.Agents.Agent.Handlers.CompactionHandler.Regenerator`.
  See `notes/update-system-msg-on-compaction.md` for the
  rationale.

  ## Loop breaker

  `check_consecutive/1` is invoked at every compaction spawn
  site (Trigger B from `ChatPipeline.maybe_compact_then_spawn/2`,
  Trigger B/C from this handler's `needs_compaction/3`, Trigger C
  from `task_compaction_request/3`). The counter increments on
  each spawn; the agent enters `:compaction_loop_detected`
  status (with `chat:compaction-loop` broadcast) when it
  exceeds `@max_consecutive_compactions`. The counter resets
  on every `:user` / `:assistant` / `:tool` append in
  `Nest.Agents.Agent.handle_call({:append_message, _, _})`.
  The user clears `:compaction_loop_detected` via
  `compaction_loop_detected_ok/3`, which restores `:idle`
  status and accepts new `chat:message` traffic.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.Handlers.CompactionHandler.Regenerator
  alias Nest.Tokens.Compactor, as: TokensCompactor

  # Consecutive compaction spawns without intervening progress
  # before we declare a loop. Tuned for `entire-ox`-shaped
  # failures: three same-iteration `:needs_compaction` requests
  # in a row, with no LLM response between them, hit this
  # threshold.
  @max_consecutive_compactions 3

  @doc """
  Dispatch a compaction message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:compaction_done, new_messages, continuation}, state) do
    compaction_done(new_messages, continuation, state)
  end

  def handle({:compaction_failed, reason, continuation}, state) do
    compaction_failed(reason, continuation, state)
  end

  def handle({:task_compaction_request, task_pid, focus}, state) do
    task_compaction_request(task_pid, focus, state)
  end

  def handle({:task_compaction_done, task_pid, new_messages}, state) do
    task_compaction_done(task_pid, new_messages, state)
  end

  def handle({:task_compaction_failed, task_pid, reason}, state) do
    task_compaction_failed(task_pid, reason, state)
  end

  def handle({:needs_compaction, _chat_turn_pid, iteration, max_iterations}, state) do
    needs_compaction(iteration, max_iterations, state)
  end

  def handle(:retry_compaction, state) do
    retry_compaction(state)
  end

  def handle(:compaction_loop_detected_ok, state) do
    compaction_loop_detected_ok(state)
  end

  defp compaction_done(new_messages, continuation, state) do
    Logger.info(
      "Compaction complete: agent=#{state.name} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    # Clear the mid-turn bookkeeping so a future retry doesn't
    # think we're still mid-turn. The continuation shape below
    # tells us whether this was a mid-turn compaction (so we
    # don't accidentally fire the wrong continuation on retry).
    state = %{state | chat_state: %{state.chat_state | mid_turn_compaction: nil}}

    # Regenerate the system prompt and persist the new messages
    # before swapping. See `regenerate_for_compaction/2` for the
    # full rationale.
    {state, new_messages} = regenerate_for_compaction(state, new_messages)

    # Archive the previous messages to history with a marker,
    # then replace state.chat_state.messages with the compacted state.
    state = compaction_completed(state, new_messages)

    case continuation do
      {:chat_continuation, :pending} ->
        # The user message was held in `state.chat_state.pending_user_message`
        # across the compaction. Append it now via
        # `ChatPipeline.resume_with_pending/1`, then spawn the new
        # chat turn. If the user clicked Stop while compaction was
        # in flight, discard the continuation — the agent's chat task
        # has already exited (or is about to) and we don't want to
        # spawn a new one.
        if state.chat_state.cancelled do
          state = clear_pending_user_message(state)
          {:noreply, state}
        else
          state = ChatPipeline.resume_with_pending(state)
          {:noreply, state}
        end

      # Legacy shape: tests that send {:compaction_done, _, {:chat_continuation, {content, mode}}}
      # directly to the agent pid. Routes through `resume_with_pending/1`
      # too — the agent's pending_user_message field is the source of
      # truth, and `resume_after_compaction/3` (the legacy alias) reads
      # from it.
      {:chat_continuation, {_content, _mode}} ->
        if state.chat_state.cancelled do
          {:noreply, state}
        else
          state = ChatPipeline.resume_with_pending(state)
          {:noreply, state}
        end

      {:task_compaction_continuation, task_pid} ->
        # The chat task invoked the `context` tool's compact action
        # and is blocked on a receive for the result. Send it the
        # new messages so it can construct the tool result string.
        # If the user clicked Stop, the chat task is no longer in
        # this receive, so the `send` is a no-op — the message lands
        # in a dead process's mailbox and is silently discarded.
        send(task_pid, {:task_compaction_done, new_messages})
        {:noreply, state}

      {:mid_turn_continuation, iteration, max_iterations} ->
        # Mid-turn compaction succeeded. Spawn a new ChatTurn
        # seeded with the compacted messages and `:mid_turn` info.
        # The new ChatTurn will see the assistant+ToolUse message
        # at the tail and execute those tool calls rather than
        # calling the LLM again. Iteration count is preserved.
        ChatPipeline.spawn_resumed_chat_turn(
          state,
          new_messages,
          iteration,
          max_iterations
        )

        {:noreply, state}
    end
  end

  defp clear_pending_user_message(state) do
    %{state | chat_state: %{state.chat_state | pending_user_message: nil}}
  end

  defp task_compaction_request(task_pid, focus, state) do
    # The chat task is mid-flow and asked for explicit
    # compaction via the `context` tool. Spawn the compactor
    # and send the result back to the task when done. The task
    # will unblock its receive and use the result.
    #
    # The `focus` argument from the tool call becomes the
    # compactor's `optional_guidance`, appended to the
    # `[mode: compact]` suffix. When nil/empty (the typical case)
    # no extra clause is added.
    state = %{state | chat_state: %{state.chat_state | status: :compacting}}
    Broadcasts.status(state.name, state)

    case check_consecutive(state) do
      :refuse ->
        # Loop detected — `check_consecutive/1` already broadcast
        # the loop event. Match the existing failure shape so
        # the awaiting chat task unblocks cleanly.
        send(task_pid, {:task_compaction_failed, :consecutive_compaction_threshold})
        {:noreply, state}

      {:ok, state} ->
        messages = state.chat_state.messages || []
        system_msg = Enum.find(messages, &match?({:system, _}, &1))
        optional_guidance = normalize_focus(focus)

        case TokensCompactor.compute_summary_budget(
               state.llm_metrics.context_limit,
               system_msg,
               messages,
               optional_guidance
             ) do
          {:ok, _n, rendered_suffix} ->
            Compaction.spawn(
              self(),
              state.client_config,
              state.llm_metrics.context_limit,
              messages,
              {:task_compaction_continuation, task_pid},
              rendered_suffix
            )

            {:noreply, state}

          {:error, :reserve_exhausted} ->
            # Surface as compaction failure so the chat task
            # unblocks with the error and the existing retry
            # path is reused.
            send(task_pid, {:task_compaction_failed, :reserve_exhausted})
            state = %{state | chat_state: %{state.chat_state | status: :compaction_failed}}
            Broadcasts.status(state.name, state)

            Broadcasts.compaction_error(
              state.name,
              "Compaction failed: #{format_reason(:reserve_exhausted)}. Click Retry to try again.",
              "Nest.Agents.Agent.Handlers.CompactionHandler.task_compaction_request/3"
            )

            {:noreply, state}
        end
    end
  end

  # The `:compact` tool's `focus` arg is whatever the LLM
  # decided to pass — a free-form string. Map `nil`, `""`, and
  # any non-binary (e.g. `:retry` from the retry-compaction
  # code path) to `nil` so the compactor's suffix logic doesn't
  # double-space or render an atom as a sentence.
  defp normalize_focus(focus) when is_binary(focus) and focus != "", do: focus
  defp normalize_focus(_other), do: nil

  defp task_compaction_done(task_pid, new_messages, state) do
    Logger.info(
      "context tool compact: agent=#{state.name} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    {state, new_messages} = regenerate_for_compaction(state, new_messages)
    state = compaction_completed(state, new_messages)
    send(task_pid, {:task_compaction_done, new_messages})
    {:noreply, state}
  end

  defp task_compaction_failed(task_pid, reason, state) do
    Logger.warning("context tool compact failed: #{inspect(reason)}")
    send(task_pid, {:task_compaction_failed, reason})
    {:noreply, state}
  end

  # Mid-turn compaction request from a ChatTurn. The ChatTurn
  # detected that the projected tool results would push the
  # conversation past the budget (post-response preflight). It
  # exited cleanly with `{:needs_compaction, self(), iteration,
  # max_iterations}`. We spawn the compactor with a continuation
  # that, on success, respawns a fresh ChatTurn with
  # `:mid_turn` info (so it executes the LLM's already-emitted
  # tool calls rather than calling the LLM again). Iteration
  # count is preserved across the compaction boundary.
  defp needs_compaction(iteration, max_iterations, state) do
    state = %{
      state
      | chat_state: %{
          state.chat_state
          | status: :compacting,
            mid_turn_compaction: %{iteration: iteration, max_iterations: max_iterations}
        }
    }

    Broadcasts.status(state.name, state)

    case check_consecutive(state) do
      :refuse ->
        # Loop detected. The awaiter in chat_turn.ex will exit
        # cleanly via the `{:needs_compaction, _, _, _}` arm of
        # the standard post-response preflight. The user gets
        # the OK button on the banner.
        {:noreply, state}

      {:ok, state} ->
        messages = state.chat_state.messages || []
        system_msg = Enum.find(messages, &match?({:system, _}, &1))

        case TokensCompactor.compute_summary_budget(
               state.llm_metrics.context_limit,
               system_msg,
               messages,
               nil
             ) do
          {:ok, _n, rendered_suffix} ->
            Compaction.spawn(
              self(),
              state.client_config,
              state.llm_metrics.context_limit,
              messages,
              {:mid_turn_continuation, iteration, max_iterations},
              rendered_suffix
            )

            {:noreply, state}

          {:error, :reserve_exhausted} ->
            # Mid-turn compaction can't proceed — the system +
            # request overflow the response budget. Surface as a
            # compaction failure via the same path as a regular
            # `{:compaction_failed, _, _}` arrival.
            compaction_failed(
              :reserve_exhausted,
              {:mid_turn_continuation, iteration, max_iterations},
              state
            )
        end
    end
  end

  # Trigger B or Trigger C compaction failed. Set Agent status
  # to `:compaction_failed`, broadcast `chat:error` + `chat:status`,
  # preserve `state.chat_state.pending_user_message` so a
  # `chat:retry-compaction` can re-attach it. The old chat task
  # has already exited (the failure message arrives after the
  # GenServer returns from `handle_cast({:chat, _, _})` and the
  # task unwinds); we do not spawn a replacement.
  #
  # The retry path is `chat:retry-compaction` →
  # `Agents.retry_compaction/1` → `Agent.retry_compaction/1` →
  # `handle_info(:retry_compaction, state)`, which re-spawns
  # `Compaction.spawn/5` with the preserved pending message.
  defp compaction_failed(reason, _continuation, state) do
    Logger.warning("Compaction failed: agent=#{state.name} reason=#{inspect(reason)}")

    state = %{state | chat_state: %{state.chat_state | status: :compaction_failed}}

    Broadcasts.status(state.name, state)

    Broadcasts.compaction_error(
      state.name,
      "Compaction failed: #{format_reason(reason)}. Click Retry to try again.",
      "Nest.Agents.Agent.Handlers.CompactionHandler.compaction_failed/3"
    )

    {:noreply, state}
  end

  # Re-spawn the compactor from `:compaction_failed` state.
  # Branches on whether the failed compaction was Trigger B
  # (user-turn boundary, `pending_user_message` is set) or
  # mid-turn (`mid_turn_compaction` is set). Both paths route
  # through the compactor and re-use the same continuation shape
  # as the original; the resulting chat turn is what differs.
  #
  # Guard: only valid when the agent is in `:compaction_failed`
  # status. If the agent is in any other state (idle, streaming,
  # compacting), this is a no-op — the retry is meaningless
  # outside of a failed-compaction context.
  defp retry_compaction(state) do
    cond do
      state.chat_state.status != :compaction_failed ->
        Logger.warning(
          "retry_compaction ignored: agent=#{state.name} status=#{inspect(state.chat_state.status)} (expected :compaction_failed)"
        )

        {:noreply, state}

      mid_turn_info = state.chat_state.mid_turn_compaction ->
        needs_compaction(mid_turn_info.iteration, mid_turn_info.max_iterations, state)

      true ->
        # Trigger B retry: user message is held in pending_user_message;
        # on success, the compactor's chat_continuation branch appends
        # it via `ChatPipeline.resume_with_pending/1`.
        task_compaction_request(self(), :retry, state)
    end
  end

  # Render the compaction failure reason as a user-facing string.
  # `:reserve_exhausted` → the system prompt + compaction request
  # consume the LLM's full response budget, so no summary can
  # fit. Tells the user to use a smaller system prompt, a model
  # with a larger context window, or to clear history. Other
  # failure modes get inspected or fall through to "internal
  # error" so users don't see raw exception text.
  defp format_reason(:reserve_exhausted),
    do:
      "system prompt + compaction request consume the LLM's full response budget — " <>
        "use a smaller system prompt or change model"

  defp format_reason(:consecutive_compaction_threshold),
    do:
      "compaction isn't reducing the conversation — start a new session, change model, or clear history"

  defp format_reason(:llm_returned_empty), do: "LLM returned empty summary"
  defp format_reason(:timeout), do: "request timed out"
  defp format_reason(:transport_error), do: "transport error"
  defp format_reason({:crash, _kind, _reason}), do: "internal error"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_other), do: "internal error"

  ## --- Loop breaker ---

  # Check whether another compaction should be allowed. Increments
  # `consecutive_compaction_count`; when the count exceeds the
  # threshold, transitions the agent to `:compaction_loop_detected`,
  # broadcasts `chat:compaction-loop`, and refuses the spawn.
  #
  # Returns `:refuse` (the spawn should not happen — caller should
  # noop or send a failure reply to any awaiter) or `{:ok, state}`
  # with the bumped counter (caller proceeds normally).
  #
  # Public so `ChatPipeline.maybe_compact_then_spawn/2` (Trigger B)
  # can run the same gate before its own spawn — keeping the
  # three Trigger sites consistent.
  @doc false
  def check_consecutive(state) do
    count = state.chat_state.consecutive_compaction_count + 1

    if count > @max_consecutive_compactions do
      _ = set_compaction_loop(state, :consecutive_compaction_threshold)
      :refuse
    else
      state = %{state | chat_state: %{state.chat_state | consecutive_compaction_count: count}}
      {:ok, state}
    end
  end

  defp set_compaction_loop(state, reason) do
    state = %{state | chat_state: %{state.chat_state | status: :compaction_loop_detected}}
    Broadcasts.status(state.name, state)

    Broadcasts.compaction_loop(
      state.name,
      format_reason(reason),
      "Nest.Agents.Agent.Handlers.CompactionHandler.set_compaction_loop/2"
    )

    state
  end

  # User clicked the OK button on the loop banner. Restore
  # `:idle` so new `chat:message` traffic resumes; reset the
  # counter to give the next compaction a fresh budget; clear any
  # held user message (the OK is an explicit acknowledgment, not
  # an implicit retry of the held message — the user types new).
  defp compaction_loop_detected_ok(state) do
    if state.chat_state.status != :compaction_loop_detected do
      Logger.warning(
        "compaction_loop_detected_ok ignored: agent=#{state.name} " <>
          "status=#{inspect(state.chat_state.status)} (expected :compaction_loop_detected)"
      )

      {:noreply, state}
    else
      state = %{
        state
        | chat_state: %{
            state.chat_state
            | status: :idle,
              consecutive_compaction_count: 0,
              pending_user_message: nil
          }
      }

      Broadcasts.status(state.name, state)
      {:noreply, state}
    end
  end

  # `__compaction_completed__` lives in the GenServer module
  # because it mutates chat history (and bumps
  # `state.chat_state.last_compaction_index`); we forward to
  # it from here.
  defp compaction_completed(state, new_messages) do
    Nest.Agents.Agent.__compaction_completed__(state, new_messages)
  end

  # Thin delegator to `Regenerator` so callers don't need to
  # know which submodule owns the implementation.
  defp regenerate_for_compaction(state, compactor_messages) do
    Regenerator.regenerate_for_compaction(state, compactor_messages)
  end
end
