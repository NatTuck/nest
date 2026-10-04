defmodule Nest.Agents.Agent.ChatTurn.ResponseHandler do
  @moduledoc """
  Response-handling logic for the ChatTurn. Extracted from
  `ChatTurn` to keep that module under the 500-line credo
  cap.

  ## Responsibilities

  - `handle/3` — entry point. Builds the `:assistant`
    message from the `RunResponse`, appends it via the
    Agent's `tool_calls_received/2` handler, dispatches the
    response by shape.
  - `dispatch_response/2` — branches by response shape:
    1. `force_finalize` is set (max-iterations second-chance)
       → finalize.
    2. Tool calls + past max iterations → synthesize error
       tool results, recurse with `force_finalize: true`.
    3. Tool calls within budget:
       a. `context-compact` solo → exit with `:compact_tool`
          continuation (compaction path).
       b. `context-compact` mixed with other tools → refuse via
          synthetic error tool results (force_finalize).
       c. Regular batch → post-response preflight; spawn the
          tool worker, OR signal `:needs_compaction` with a
          `:tool_call` continuation so the Agent runs
          mid-turn compaction.
    4. Final text response:
       a. Truncated by the output token limit → append a "keep going"
          user nudge and re-ask (bounded), so a cut-off reply is
          continued rather than accepted.
       b. No visible text/refusal (thinking-only) → append an empty-
          response nudge and re-ask (bounded).
       c. Otherwise → finalize.
  - `extract_tool_calls_from_parts/1` — public helper used
    by the live response path (here).
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Agents.Agent.ChatTurn.Lifecycle
  alias Nest.Agents.Agent.ChatTurn.Messages
  alias Nest.Agents.Agent.ChatTurn.NoticeInjector
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator, as: TokensEstimator

  require Logger

  # A model can end a turn having streamed only reasoning
  # (`reasoning_content`) and no actual reply text. We don't treat
  # that as a finished answer: inject a user nudge and re-ask, up to
  # this many times, before giving up and finalizing.
  @max_empty_retries 2

  # The escalating nudge texts, one per retry. Prior nudges are
  # detected by exact text match against the message history (they're
  # real user messages), so the count lives in the conversation rather
  # than in ChatTurn state.
  @empty_nudges [
    "You gave an empty response, which you shouldn't do. What were you saying?",
    "You did it again — another empty response with no actual text. " <>
      "Write out your real reply as text now."
  ]

  # A response cut off by the output token limit (Anthropic
  # `max_tokens`, OpenAI `length`) is not a finished answer. Send a
  # continuation nudge and re-ask, up to this many times, before giving
  # up and finalizing.
  @max_truncation_retries 2

  @truncation_nudge "Keep going. Your previous response hit the output token limit — " <>
                      "continue exactly where you left off, and don't repeat what you already wrote."

  @doc """
  Build the `:assistant` message from the LLM response,
  broadcast the response api_log, then dispatch by response
  shape. Returns the same `GenServer.reply/3` tuple the
  caller would normally emit — the chat turn just forwards
  it.

  `chat_turn_pid` is needed so we can route "send the
  {:iterate, from} after the synthetic-error path" back
  through the chat turn's mailbox (we can't use
  `GenServer.reply/3` from a helper module).
  """
  @spec handle(RunResponse.t(), State.t(), pid()) :: GenServer.reply()
  def handle(response, state, chat_turn_pid) do
    state = %{state | active_worker: nil, active_worker_kind: nil}

    send(state.ctx.agent_pid, {:llm_usage, response.usage})

    # Build the assistant message and broadcast it via the
    # Agent's handler — that handler stamps the index.
    {role, msg} = Messages.assistant(response)

    # Case 2 injection. Collect notice specs from all trigger
    # sources (context-usage threshold, budget reminder) and
    # inject each as a synthetic [assistant(attention), user(notice)]
    # pair immediately before the assistant message. When both
    # fire on the same iteration, both pairs are injected — the
    # LLM sees all the information and the UI shows what was
    # sent (4 extra messages, no deferral trick).
    #
    # Each spec carries its own attention text ("Context?" for
    # context, "Tool limit?" for budget) so the LLM can
    # distinguish notice types.
    #
    # The pair is always wire-safe: prior is wire :user (last
    # user/tool message), then assistant, then user, then this
    # assistant message — strict alternation.
    #
    # The implementation lives in `NoticeInjector` to keep this
    # module under the 500-line credo cap.
    {injected, state} = NoticeInjector.inject_all(response, state)

    # The synthetic pair (when injected) shifts the assistant
    # message's index by 2. `active_message_index` was set to
    # the pre-injection expected index; advance it to the
    # actual index so the stored response log keys to the right
    # message.
    state = %{state | active_message_index: state.active_message_index + 2 * injected}

    # Store the response log on the assistant message before it is
    # appended, so the message is persisted complete (in memory, in
    # the DB, and in the default UI payload in one shot).
    response_log = APILog.store_response_log(state.active_message_index, response)
    assistant_msg = {role, %{msg | api_logs: [response_log]}}

    if defer_response?(response, state, assistant_msg) do
      defer_response(state, assistant_msg)
    else
      dispatch_response(response, state, chat_turn_pid, assistant_msg)
    end
  end

  @doc """
  Filter non-ToolUse parts and convert each remaining
  `%Part.ToolUse{}` to a `ToolCall` with the same `id`,
  `name`, and `arguments`.
  """
  @spec extract_tool_calls_from_parts([Part.t()]) :: [Nest.Messages.ToolCall.t()]
  def extract_tool_calls_from_parts(parts) do
    parts
    |> Enum.filter(&match?(%Part.ToolUse{}, &1))
    |> Enum.map(fn %Part.ToolUse{id: id, name: name, arguments: arguments} ->
      %Nest.Messages.ToolCall{id: id, name: name, arguments: arguments || %{}}
    end)
  end

  # Dispatch on the response shape after the assistant message
  # has been appended. For the compactor's own chat turn, the
  # finalization path sends `{:compaction_done, ...}` instead
  # of `{:chat_idle, _}` (the Agent's `Compaction.ResultHandler`
  # is the next stage).
  defp dispatch_response(response, state, chat_turn_pid, assistant_msg) do
    cond do
      compactor_entry?(state) ->
        Lifecycle.finalize_compaction(state, response, assistant_msg)

      state.force_finalize ->
        # The message is the provider's actual response; persist it before
        # ending the turn.
        persist_assistant(state, assistant_msg)
        Lifecycle.finalize_turn(state)

      RunResponse.has_tool_calls?(response) and state.iteration > state.max_iterations ->
        handle_overflow_tool_calls(response, state, chat_turn_pid, assistant_msg)

      RunResponse.has_tool_calls?(response) ->
        handle_normal_tool_calls(response, state, assistant_msg)

      empty_assistant?(assistant_msg) ->
        # A provider response with no text, thinking, refusal, or tool
        # call at all would persist a zero-part assistant message. Never
        # do that: surface it as a non-empty error and end the turn.
        send(
          state.ctx.agent_pid,
          {:llm_error, "The model returned a response with no content."}
        )

        Lifecycle.finalize_turn(state)

      true ->
        persist_assistant(state, assistant_msg)
        finalize_or_reprompt(response, state)
    end
  end

  defp empty_assistant?({:assistant, %Assistant{parts: parts}}), do: parts == []

  # Persist the assistant message through the Agent's canonical append path.
  # Tool-call responses are persisted only once their batch is confirmed to
  # fit (see `handle_regular_tool_calls/3`); a deferred batch never persists.
  defp persist_assistant(state, assistant_msg) do
    send(state.ctx.agent_pid, {:tool_calls_received, assistant_msg})
  end

  # A final response is "silent" when it offers the user no visible
  # content — no text (blank/whitespace counts) and no refusal.
  # Reasoning/thinking alone doesn't count as a reply: a model that
  # ends its turn after thinking with no actual text has dead-ended
  # the conversation.
  defp silent_response?(response) do
    not has_visible_text?(response.text) and not has_visible_text?(response.refusal)
  end

  defp has_visible_text?(nil), do: false
  defp has_visible_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp has_visible_text?(_), do: false

  # Don't silently accept a no-text response as a finished reply.
  # Append an explicit (angry) user nudge and take another swing,
  # bounded by `@max_empty_retries`. After the cap, finalize with a
  # warning — the thinking-only assistant is already visible, we just
  # couldn't get the model to speak. Prior nudges are counted from the
  # message history (each is a distinct, exact-matching user message),
  # so the retry count is conversation state, not ChatTurn state.
  #
  # Non-silent responses finalize immediately — no message-history
  # round-trip is paid on the hot path.
  defp finalize_or_reprompt(response, state) do
    cond do
      RunResponse.truncated?(response) -> handle_truncated_response(state)
      silent_response?(response) -> handle_silent_response(state)
      true -> Lifecycle.finalize_turn(state)
    end
  end

  defp handle_silent_response(state) do
    nudges = count_prior_nudges(state)

    if nudges < @max_empty_retries do
      reprompt_or_finalize(state, Enum.at(@empty_nudges, nudges))
    else
      Logger.warning(
        "Empty assistant response finalized after #{@max_empty_retries} re-prompt(s): " <>
          "no text or refusal content"
      )

      Lifecycle.finalize_turn(state)
    end
  end

  # Don't accept a truncated response as a finished reply. Append a real
  # user nudge asking the model to continue and take another swing,
  # bounded by `@max_truncation_retries`. Prior nudges are counted from
  # the message history (each is an exact-matching user message), so the
  # retry count is conversation state, not ChatTurn state.
  defp handle_truncated_response(state) do
    if count_prior_messages(state, [@truncation_nudge]) < @max_truncation_retries do
      reprompt_or_finalize(state, @truncation_nudge)
    else
      Logger.warning(
        "Truncated assistant response finalized after #{@max_truncation_retries} " <>
          "keep-going re-prompt(s)"
      )

      Lifecycle.finalize_turn(state)
    end
  end

  defp reprompt_or_finalize(state, nudge_text) do
    if append_user_nudge(state, nudge_text) do
      Process.send(self(), :iterate, [])
      {:noreply, state}
    else
      # Agent unreachable — don't spin; finalize with what we have.
      Lifecycle.finalize_turn(state)
    end
  end

  # How many empty-response nudges are already in the message history.
  defp count_prior_nudges(state), do: count_prior_messages(state, @empty_nudges)

  # How many of the given exact-text user messages are already in the
  # message history.
  defp count_prior_messages(state, texts) do
    messages =
      try do
        GenServer.call(state.ctx.agent_pid, :get_messages, 1_000)
      catch
        :exit, _ -> []
      end

    messages
    |> Enum.count(fn
      {:user, %{parts: [%Part.Text{text: text}]}} when is_binary(text) ->
        text in texts

      _ ->
        false
    end)
  end

  # Append the nudge as a real user message so it's persisted,
  # broadcast, and sent to the LLM on the next iteration. Returns
  # `true` on success (agent still alive); `false` if the append
  # fails or the agent has gone away.
  defp append_user_nudge(state, text) do
    if nudge_over_budget?(state, text) do
      false
    else
      user_message = ContextReminder.build_user_notice(text, nil)

      case GenServer.call(state.ctx.agent_pid, {:append_messages, [user_message]}, 5_000) do
        [_ | _] -> true
        _ -> false
      end
    end
  catch
    :exit, _ -> false
  end

  # A re-prompt nudge is ordinary content and must not spend the
  # compaction reserve; when there is no room, finalize instead.
  defp nudge_over_budget?(state, text) do
    limit = state.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      messages =
        try do
          {msgs, _} = GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled, 1_000)
          msgs
        catch
          :exit, _ -> []
        end

      Budget.remaining(messages, limit) < TokensEstimator.estimate(text)
    else
      false
    end
  end

  # True when this ChatTurn is the compactor's own chat turn
  # (the entry was `{:compaction, _, _}`). The finalization
  # path uses `finalize_compaction/2` instead of `finalize_turn/1`.
  defp compactor_entry?(%State{entry: {:compaction, _, _}}), do: true
  defp compactor_entry?(_), do: false

  # Defer a completed final reply when adding it would spend the compaction
  # reserve. Truncated and silent responses are left to the re-prompt paths
  # (a nudge, not a deferral).
  defp defer_response?(response, state, assistant_msg) do
    not compactor_entry?(state) and
      not state.force_finalize and
      not RunResponse.has_tool_calls?(response) and
      not RunResponse.truncated?(response) and
      not silent_response?(response) and
      over_budget?(assistant_msg, state.ctx.context_limit)
  end

  # The reply's own `usage` (input + cache + output) is the real size of the
  # context including it, so we can decide without a round-trip to the Agent
  # (the reply is the newest anchored message).
  defp over_budget?(assistant_msg, limit), do: not Budget.fits?([assistant_msg], limit)

  defp defer_response(state, assistant_msg) do
    continuation = {:assistant_response, assistant_msg, state.iteration, state.max_iterations}
    send(state.ctx.agent_pid, {:needs_compaction, self(), continuation})

    Logger.info(
      "ChatTurn: emitting :needs_compaction with :assistant_response continuation " <>
        "(iter=#{state.iteration}, max=#{state.max_iterations})"
    )

    {:stop, :normal, state}
  end

  # Past max iterations, LLM still emitted tool calls (the
  # `tools: nil` was supposed to prevent this but some
  # providers ignore it). Synthesize error tool results,
  # recurse with `force_finalize: true` so the next call
  # always finalizes regardless of what the LLM does.
  defp handle_overflow_tool_calls(response, state, chat_turn_pid, assistant_msg) do
    persist_assistant(state, assistant_msg)
    tool_msg = Messages.synthetic_error_tool_results(response)
    _stamped_tool = GenServer.call(state.ctx.agent_pid, {:append_message, tool_msg})
    state = %{state | force_finalize: true}
    send(chat_turn_pid, :iterate)
    {:noreply, state}
  end

  # Normal tool calls within budget. Three sub-cases by batch shape:
  #
  # 1. `context-compact` is the SOLE tool call → Trigger 3. The
  #    chat turn exits with `{:compact_tool, [tool_call,
  #    synthetic_tool_result], iter, max_iter}` and the Agent
  #    runs the compactor. (No tool worker is ever spawned for
  #    `context-compact`; the BlockedToolWorker pattern is gone.)
  #
  # 2. `context-compact` is mixed with other tools → REFUSE with
  #    a synthetic error tool result appended to messages. The
  #    chat turn forces `finalize: true` and iterates again so
  #    the LLM sees the constraint on the next call. The
  #    regular tool worker is never spawned.
  #
  # 3. Regular batch (no `context-compact`) → post-response
  #    preflight; spawn the tool worker, OR build a
  #    `{:tool_call, _, _, _}` continuation and exit (Trigger 2)
  #    so the Agent can run a mid-turn compaction.
  defp handle_normal_tool_calls(response, state, assistant_msg) do
    cond do
      compact_only?(response.tool_calls) ->
        handle_compact_only(response, state, assistant_msg)

      contains_compact?(response.tool_calls) ->
        refuse_compact_mixed(response, state, assistant_msg)

      true ->
        handle_regular_tool_calls(response, state, assistant_msg)
    end
  end

  defp compact_only?([
         %Nest.Messages.ToolCall{name: "context-compact"}
       ]),
       do: true

  defp compact_only?(_), do: false

  defp contains_compact?(tool_calls) do
    Enum.any?(tool_calls, fn
      %Nest.Messages.ToolCall{name: "context-compact"} -> true
      _ -> false
    end)
  end

  # Trigger 3 path: the LLM emitted `context-compact` as the only
  # tool call. Build the continuation, send `:needs_compaction` to
  # the Agent with the continuation payload, and exit cleanly.
  # The Agent runs the compactor, commits the compaction, and `compaction_done/3`
  # spawns a fresh ChatTurn via `ChatTurnSpawner.spawn/4`.
  #
  # The synthetic tool result is built here at the trigger site (we
  # still have live `state.chat_state.messages` pre-compaction) using
  # `length(state.chat_state.messages)`-estimated pre-compaction token
  # count for the message string. We don't need exact post-compaction
  # counts — the new system prompt carries the catalog entry
  # with the spec text, and the summary user-message replaces the
  # archived content.
  defp handle_compact_only(response, state, assistant_msg) do
    tool_call = hd(response.tool_calls)

    # `ctx.messages` was captured at spawn time and reflects the
    # pre-compaction message list — exactly what we want for the
    # "compacted from N tokens" approximation. The actual
    # post-compaction token count depends on the compactor's output,
    # which isn't available here at the trigger site.
    pre_count = TokensEstimator.estimate_messages(state.ctx.messages || [])

    synthetic_result = build_synthetic_compact_result(tool_call, pre_count)

    continuation = {
      :compact_tool,
      [assistant_msg, synthetic_result],
      state.iteration,
      state.max_iterations
    }

    send(state.ctx.agent_pid, {:needs_compaction, self(), continuation})

    Logger.info(
      "ChatTurn: emitting :needs_compaction with :compact_tool continuation " <>
        "(iter=#{state.iteration}, max=#{state.max_iterations})"
    )

    {:stop, :normal, state}
  end

  # `context-compact` is in the batch but not alone. Refuse the
  # whole batch with synthetic error tool results so the LLM
  # retries without `context-compact` mixed in. Same shape as
  # `handle_overflow_tool_calls/3`: append tool_msg, set
  # `force_finalize: true`, iterate.
  defp refuse_compact_mixed(response, state, assistant_msg) do
    persist_assistant(state, assistant_msg)

    tool_msg =
      Messages.refuse_context_compact_co_batch(
        response.tool_calls,
        state.ctx.messages || state.chat_state_messages || []
      )

    _stamped_tool = GenServer.call(state.ctx.agent_pid, {:append_message, tool_msg})
    state = %{state | force_finalize: true}
    send(self(), :iterate)
    {:noreply, state}
  end

  # Build a synthetic tool-result message for the `context-compact`
  # tool. The `tool_call_id` matches the carried
  # `assistant+ToolUse` so the LLM's tool_use/tool_result pair is
  # preserved across the compaction boundary.
  @spec build_synthetic_compact_result(Nest.Messages.ToolCall.t(), non_neg_integer()) ::
          {:tool, Tool.t()}
  defp build_synthetic_compact_result(tool_call, pre_count) do
    {:tool,
     %Tool{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [
         %Part.ToolResult{
           tool_call_id: tool_call.id,
           name: "context-compact",
           arguments: tool_call.arguments,
           content: "Compacted from #{pre_count} token previous context.",
           is_error: false
         }
       ],
       api_logs: []
     }}
  end

  # Regular path: preflight on the projected tool results. If
  # they'd push past budget, exit cleanly with a `:tool_call`
  # continuation (Trigger 2); otherwise spawn the tool worker.
  #
  # The `:tool_call` continuation carries the just-built (and
  # response-logged) assistant message so the copy re-appended after
  # the mid-turn compaction commit is stored complete, never incomplete.
  defp handle_regular_tool_calls(response, state, assistant_msg) do
    case post_response_preflight(response.tool_calls, state, assistant_msg) do
      :fits ->
        persist_assistant(state, assistant_msg)
        Agent.ChatTurn.spawn_tool_worker(state, response.tool_calls)

      {:refuse, _reason} ->
        continuation = {
          :tool_call,
          assistant_msg,
          state.iteration,
          state.max_iterations
        }

        send(state.ctx.agent_pid, {:needs_compaction, self(), continuation})

        Logger.info(
          "ChatTurn: emitting :needs_compaction with :tool_call continuation " <>
            "(iter=#{state.iteration}, max=#{state.max_iterations})"
        )

        {:stop, :normal, state}
    end
  end

  # Post-response preflight: would sending the projected tool results
  # push us over `(context_limit - reserve)`? Reuses `BatchSizer.preflight/2`
  # so the per-tool projection logic stays in one place. The fresh
  # messages list (post-LLM-response, pre-tool-execution) is what
  # the BatchSizer checks; the same projection the chat pipeline
  # uses at user-turn boundaries.
  defp post_response_preflight(tool_calls, state, assistant_msg) do
    {messages, _} = GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled)
    # The assistant message is confirmed-then-persisted, so it is not in the
    # Agent's list yet; include it so the projection reflects what would be
    # sent.
    ctx = %{state.ctx | messages: messages ++ [assistant_msg]}
    BatchSizer.preflight(tool_calls, ctx)
  end
end
