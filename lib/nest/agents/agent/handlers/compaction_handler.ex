defmodule Nest.Agents.Agent.Handlers.CompactionHandler do
  @moduledoc """
  `handle_info/2` handlers for compaction-related events:
  `{:compaction_done, _, _}`, `{:compaction_failed, _, _}`,
  `{:needs_compaction, _, _}`, `:retry_compaction`,
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

  ## Continuation shapes

  The `{:compaction_done, _, continuation}` and
  `{:compaction_failed, _, continuation}` messages carry a
  `continuation` payload of one of three shapes (see
  `Nest.Agents.Agent.ChatTurn.State`):

    * `{:user_message, User.t()}`
    * `{:tool_call, Assistant.t(), non_neg_integer(), pos_integer()}`
    * `{:compact_tool, tool_pair, non_neg_integer(), pos_integer()}`

  `compaction_done/3` reads the shape to know what to append
  after the swap (which carried messages end up in the
  post-compaction active list) and which `ChatTurnSpawner`
  call to make (all of which funnel through one function).
  No `state.chat_state.messages` inspection happens after
  compaction; the continuation payload is the contract.

  ## `:passthrough` short-circuit

  When the compactor's `:too_short` branch fires
  (`{:compaction_done, :passthrough, continuation}`), there is
  no LLM response to record, no swap to perform, and no
  summary to build. The handler logs a warning, clears the
  mid-turn bookkeeping, and dispatches straight to spawning
  the next chat turn (or `:idle` if there is no continuation).
  `state.chat_state.messages`, `history`, and
  `last_compaction_index` are unchanged.

  ## Loop breaker

  `check_consecutive/1` is invoked at every compaction spawn
  site (Trigger B from `ChatPipeline.maybe_compact_then_spawn/2`,
  the two Trigger B/C branches from this handler's
  `needs_compaction/3`). The counter increments on each
  spawn; the agent enters `:compaction_loop_detected` status
  (with `chat:compaction-loop` broadcast) when it exceeds
  `@max_consecutive_compactions`. The counter resets on every
  `:user` / `:assistant` / `:tool` append in
  `Nest.Agents.Agent.handle_call({:append_message, _, _})`.
  The user clears `:compaction_loop_detected` via
  `compaction_loop_detected_ok/3`, which restores `:idle`
  status and accepts new `chat:message` traffic.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.ChatTurnSpawner
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.Handlers.CompactionHandler.Regenerator
  alias Nest.Agents.Agent.Handlers.CompactionHandler.Retry
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
  def handle({:compaction_done, summary_text, continuation}, state) do
    compaction_done(summary_text, continuation, state)
  end

  def handle({:compaction_failed, reason, continuation}, state) do
    compaction_failed(reason, continuation, state)
  end

  def handle({:needs_compaction, _chat_turn_pid, continuation}, state) do
    needs_compaction(continuation, state)
  end

  def handle(:retry_compaction, state) do
    Retry.retry_compaction(state)
  end

  def handle(:compaction_loop_detected_ok, state) do
    compaction_loop_detected_ok(state)
  end

  @doc """
  The compactor returned. Three branches:

    * `:passthrough` — the conversation was too short to compact.
      Log a warning, clear mid-turn bookkeeping, dispatch to
      the next chat turn (or `:idle` if no continuation). No
      swap, no archive, no marker.
    * `String.t()` — the LLM summary text. Regenerate the
      system prompt, build the post-compaction
      "Summary of earlier conversation:" user message (with
      `<think>` blocks stripped), append the continuation tail,
      swap, and spawn the next chat turn.

  Common path for all three trigger types — the continuation
  payload is the `Nest.Agents.Agent.ChatTurn.State.continuation/0`
  shape (`:user_message`, `:tool_call`, `:compact_tool`) that
  `ChatTurnSpawner.spawn/4` consumes directly.
  """
  def compaction_done(:passthrough, continuation, state) do
    handle_passthrough(continuation, state)
  end

  def compaction_done(summary_text, continuation, state) when is_binary(summary_text) do
    Logger.info(
      "Compaction complete: agent=#{state.name} from=#{length(state.chat_state.messages)} " <>
        "summary_chars=#{String.length(summary_text)} " <>
        "continuation=#{continuation_tag(continuation)}"
    )

    # Clear the mid-turn bookkeeping so a future retry doesn't
    # think we're still mid-turn. The continuation shape tells
    # us whether this was a mid-turn compaction (so we don't
    # accidentally fire the wrong continuation on retry).
    state = %{state | chat_state: %{state.chat_state | mid_turn_compaction: nil}}

    # Regenerate the system prompt + build the
    # "Summary of earlier conversation:" user message from
    # `summary_text`. The strip is applied inside the
    # regenerator.
    {state, new_messages} = regenerate_for_compaction(state, summary_text)

    new_messages = append_continuation_tail(new_messages, continuation)

    # Archive the previous messages to history with a marker,
    # then replace state.chat_state.messages with the compacted state.
    state = compaction_completed(state, new_messages)

    state = spawn_chat_turn_for_continuation(state, new_messages, continuation)
    {:noreply, state}
  end

  @doc """
  Append the carried messages to `new_messages`. Each tuple
  format is the unified continuation shape — the carried
  struct(s) end up at the post-swap tail so the new
  ChatTurn's first iter reads them from
  `state.chat_state.messages`.

  `:user_message` carries a bare `User.t()` (no role
  wrapper); the append wraps it in `{:user, _}` to match
  the rest of the messages list. `:tool_call` and
  `:compact_tool` already carry wrapped messages.
  """
  def append_continuation_tail(new_messages, {:user_message, msg}),
    do: new_messages ++ [{:user, msg}]

  def append_continuation_tail(new_messages, {:tool_call, msg, _, _}),
    do: new_messages ++ [msg]

  def append_continuation_tail(
        new_messages,
        {:compact_tool, [tool_call_msg, tool_result_msg], _, _}
      ),
      do: new_messages ++ [tool_call_msg, tool_result_msg]

  @doc """
  Spawn a fresh ChatTurn that resumes the chat turn's iteration.
  Resolves the capability map, builds the ctx, and delegates
  to `ChatTurnSpawner.spawn/4`. One unified entry point for
  all three triggers — the continuation tag carries the
  per-trigger semantics.
  """
  def spawn_chat_turn_for_continuation(state, new_messages, continuation) do
    {_effective_mode, caps} = resolve_caps(state)
    ChatTurnSpawner.spawn(state, new_messages, continuation, caps)
  end

  defp resolve_caps(state) do
    ChatPipeline.resolve_mode_and_caps(state.mode, state.vocation)
  end

  # Debug-friendly tag for the log line.
  defp continuation_tag({:user_message, _}), do: :user_message
  defp continuation_tag({:tool_call, _, _, _}), do: :tool_call
  defp continuation_tag({:compact_tool, _, _, _}), do: :compact_tool

  # Mid-turn compaction request from a ChatTurn. The ChatTurn
  # detected (a) projected tool results would push past
  # `context_limit - reserve` and emitted its tool calls via
  # the `:tool_call` continuation, OR (b) the LLM emitted
  # `context.compact` and the chat turn exited with the
  # `:compact_tool` continuation. Both paths get here — the
  # continuation shape carries the resume payload. We spawn
  # the compactor with `{:ok, state}`-gate via
  # `check_consecutive/1`, run the compactor, and on success
  # `compaction_done/3` respawns a fresh ChatTurn via
  # `ChatTurnSpawner.spawn/4` (reading the continuation).
  # Public so `Retry.retry_compaction/1` (mid-turn retry branch)
  # can re-spawn the compactor with the preserved continuation
  # payload. `check_consecutive/1` is run again — counter was
  # not reset between the failed spawn and the retry.
  def needs_compaction(continuation, state) do
    state = %{
      state
      | chat_state: %{
          state.chat_state
          | status: :compacting,
            mid_turn_compaction: %{continuation: continuation}
        }
    }

    Broadcasts.status(state.name, state)

    case check_consecutive(state) do
      :refuse ->
        # Loop detected. Send a failure reply so the awaiter
        # in the chat turn unblocks cleanly with the loop
        # reason. The user gets the OK button on the banner.
        send_compaction_failed(state, :consecutive_compaction_threshold, continuation)
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
              continuation,
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
              continuation,
              %{state | chat_state: %{state.chat_state | status: :compaction_failed}}
            )
        end
    end
  end

  # Send `{:compaction_failed, reason, continuation}` to the
  # chat turn so its blocking receive unblocks cleanly with the
  # loop reason. Used when `check_consecutive/1` returns `:refuse`
  # at the spawn site (no compactor was actually run).
  defp send_compaction_failed(state, reason, continuation) do
    send(
      state.chat_state.mid_turn_compaction[:chat_turn_pid] || self(),
      {:compaction_failed, reason, continuation}
    )
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

  # Re-spawn the compactor from `:compaction_failed` state —
  # extracted to `Nest.Agents.Agent.Handlers.CompactionHandler.Retry`
  # so this module stays under credo's 500-line cap. The handler
  # dispatches via `handle(:retry_compaction, _)` above.

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
  # two Trigger sites consistent.
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
  defp regenerate_for_compaction(state, summary_text) do
    Regenerator.regenerate_for_compaction(state, summary_text)
  end

  # `:too_short` branch: compactor returned `{:ok, :passthrough}`
  # because the input was too small to compact. There is no LLM
  # response to record, no swap to perform, and no summary to
  # build. Clear mid-turn bookkeeping, return to `:idle`, and
  # either dispatch the next chat turn (if a continuation is
  # pending) or just `:noreply` with the cleaned-up state.
  defp handle_passthrough(continuation, state) do
    # The conversation was too short to compact (`:too_short`
    # branch in `Nest.Tokens.Compactor.compact/3`). There's no
    # LLM response to record, no swap to perform, and no
    # summary to build — just resume with the carry-over.
    # Log at `:debug` (silent at the default `:warning` level
    # in test and production) so operators can surface it
    # during diagnostics without test noise. Matches how
    # `Regenerator.maybe_fresh_vocation/1` handles its
    # `:not_found` lookup.
    Logger.debug(fn ->
      "Compaction skipped: agent=#{state.name} (conversation too short to compact)"
    end)

    state = %{
      state
      | chat_state: %{state.chat_state | mid_turn_compaction: nil, status: :idle}
    }

    Broadcasts.status(state.name, state)

    case continuation do
      nil ->
        {:noreply, state}

      # `spawn_chat_turn_for_continuation/3` returns the bare
      # `state` struct (see `ChatTurnSpawner.spawn/4`'s
      # `@spec`). Wrap in `{:noreply, state}` so the GenServer
      # callback returns a valid reply tuple — returning the
      # struct directly is a "bad return value" that crashes
      # the GenServer (the failure surfaced in
      # `agent_chat_turn_iteration_test.exs:144`).
      _ ->
        {:noreply,
         spawn_chat_turn_for_continuation(state, state.chat_state.messages, continuation)}
    end
  end
end
