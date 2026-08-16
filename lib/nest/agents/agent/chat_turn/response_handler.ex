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
    4. Final text response → finalize.
  - `extract_tool_calls_from_parts/1` — public helper used
    by the live response path (here).
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.Lifecycle
  alias Nest.Agents.Agent.ChatTurn.Messages
  alias Nest.Agents.Agent.ChatTurn.NoticeInjector
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Tokens.Estimator, as: TokensEstimator

  require Logger

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
    # Agent's handler — that handler stamps the index and
    # attaches any pending api_logs.
    {role, msg} = Messages.assistant(response)
    assistant_msg = {role, msg}

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
    # actual index so the api_log below keys to the right
    # message.
    state = %{state | active_message_index: state.active_message_index + 2 * injected}

    send(state.ctx.agent_pid, {:tool_calls_received, assistant_msg})

    _ = APILog.response(state, state.active_message_index, response)

    dispatch_response(response, state, chat_turn_pid)
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
  defp dispatch_response(response, state, chat_turn_pid) do
    cond do
      compactor_entry?(state) ->
        Lifecycle.finalize_compaction(state, response)

      state.force_finalize ->
        Lifecycle.finalize_turn(state)

      RunResponse.has_tool_calls?(response) and state.iteration > state.max_iterations ->
        handle_overflow_tool_calls(response, state, chat_turn_pid)

      RunResponse.has_tool_calls?(response) ->
        handle_normal_tool_calls(response, state)

      true ->
        Lifecycle.finalize_turn(state)
    end
  end

  # True when this ChatTurn is the compactor's own chat turn
  # (the entry was `{:compaction, _, _}`). The finalization
  # path uses `finalize_compaction/2` instead of `finalize_turn/1`.
  defp compactor_entry?(%State{entry: {:compaction, _, _}}), do: true
  defp compactor_entry?(_), do: false

  # Past max iterations, LLM still emitted tool calls (the
  # `tools: nil` was supposed to prevent this but some
  # providers ignore it). Synthesize error tool results,
  # recurse with `force_finalize: true` so the next call
  # always finalizes regardless of what the LLM does.
  defp handle_overflow_tool_calls(response, state, chat_turn_pid) do
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
  defp handle_normal_tool_calls(response, state) do
    cond do
      compact_only?(response.tool_calls) ->
        handle_compact_only(response, state)

      contains_compact?(response.tool_calls) ->
        refuse_compact_mixed(response, state)

      true ->
        handle_regular_tool_calls(response, state)
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
  # The Agent runs the compactor, swaps messages, and `compaction_done/3`
  # spawns a fresh ChatTurn via `ChatTurnSpawner.spawn/4`.
  #
  # The synthetic tool result is built here at the trigger site (we
  # still have live `state.chat_state.messages` pre-swap) using
  # `length(state.chat_state.messages)`-estimated pre-swap token
  # count for the message string. We don't need exact post-swap
  # counts — the new system prompt carries the catalog entry
  # with the spec text, and the summary user-message replaces the
  # archived content.
  defp handle_compact_only(response, state) do
    assistant_msg = extract_assistant_msg(response)
    tool_call = hd(response.tool_calls)

    # `ctx.messages` was captured at spawn time and reflects the
    # pre-swap message list — exactly what we want for the
    # "compacted from N tokens" approximation. The actual
    # post-swap token count depends on the compactor's output,
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
  defp refuse_compact_mixed(response, state) do
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

  # Pulls the just-appended `{:assistant, _}` message out of
  # the response (it's not yet on the agent — the append happens
  # via `{:tool_calls_received, _}` in `handle/3` before this
  # branch fires, so by the time we get here, `state.ctx.messages`
  # was the pre-handle snapshot; we just rebuild from the
  # `RunResponse.tool_calls` and the same body the messages
  # builder produced).
  #
  # We rebuild instead of reading `state.ctx.messages` because
  # `state.ctx.messages` at this point still holds the
  # pre-append value (the assistant was appended into the agent
  # via send, which is async). The carry-forward needs the
  # post-append struct.
  defp extract_assistant_msg(response) do
    {role, struct} = Messages.assistant(response)
    {role, struct}
  end

  # Regular path: preflight on the projected tool results. If
  # they'd push past budget, exit cleanly with a `:tool_call`
  # continuation (Trigger 2); otherwise spawn the tool worker.
  defp handle_regular_tool_calls(response, state) do
    case post_response_preflight(response.tool_calls, state) do
      :fits ->
        Agent.ChatTurn.spawn_tool_worker(state, response.tool_calls)

      {:refuse, _reason} ->
        # Trigger 2: build the `:tool_call` continuation from the
        # just-appended assistant message (last in
        # `state.ctx.messages` was the user; the response's
        # assistant is the freshly-built one we rebuild here).
        assistant_msg = extract_assistant_msg(response)

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
  defp post_response_preflight(tool_calls, state) do
    {messages, _} = GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled)
    ctx = %{state.ctx | messages: messages}
    BatchSizer.preflight(tool_calls, ctx)
  end
end
