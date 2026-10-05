defmodule Nest.Agents.Agent.Turn.ResponseHandler do
  @moduledoc """
  Response-handling logic for the in-process turn driver.

  Operates on the Agent state directly. Appends go through
  `MessageAppender`; state transitions (`streaming` →
  `executing_tools` → `streaming`) go through the extracted handler
  bodies (`LLMStreamHandler`) so there is one implementation shared
  with `handle_info`-driven events.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler
  alias Nest.Agents.Agent.Machine.Turn
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.Turn.APILog
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Iteration
  alias Nest.Agents.Agent.Turn.Lifecycle
  alias Nest.Agents.Agent.Turn.Messages
  alias Nest.Agents.Agent.Turn.NoticeInjector
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator, as: TokensEstimator

  require Logger

  @max_empty_retries 2

  @empty_nudges [
    "You gave an empty response, which you shouldn't do. What were you saying?",
    "You did it again — another empty response with no actual text. " <>
      "Write out your real reply as text now."
  ]

  @max_truncation_retries 2

  @truncation_nudge "Keep going. Your previous response hit the output token limit — " <>
                      "continue exactly where you left off, and don't repeat what you already wrote."

  @doc """
  Build the `:assistant` message from the LLM response, broadcast the
  response api_log, then dispatch by response shape. Returns
  `{:noreply, state}`.
  """
  @spec handle(RunResponse.t(), Agent.t()) :: {:noreply, Agent.t()}
  def handle(response, state) do
    state = clear_worker(state)

    state = LLMStreamHandler.llm_usage_state(response.usage, state)

    {role, msg} = Messages.assistant(response)

    {injected, state} = NoticeInjector.inject_all(response, state)

    state = advance_active_index(state, 2 * injected)

    {response_log, state} = APILog.store_response_log(state, active_index(state), response)
    assistant_msg = {role, %{msg | api_logs: [response_log]}}

    if defer_response?(response, state, assistant_msg) do
      defer_response(state, assistant_msg)
    else
      dispatch_response(response, state, assistant_msg)
    end
  end

  @doc """
  Filter non-ToolUse parts and convert each remaining
  `%Part.ToolUse{}` to a `ToolCall`.
  """
  @spec extract_tool_calls_from_parts([Part.t()]) :: [Nest.Messages.ToolCall.t()]
  def extract_tool_calls_from_parts(parts) do
    parts
    |> Enum.filter(&match?(%Part.ToolUse{}, &1))
    |> Enum.map(fn %Part.ToolUse{id: id, name: name, arguments: arguments} ->
      %Nest.Messages.ToolCall{id: id, name: name, arguments: arguments || %{}}
    end)
  end

  defp dispatch_response(response, state, assistant_msg) do
    case classify(response, state, assistant_msg) do
      :compaction ->
        Lifecycle.finalize_compaction(state, response, assistant_msg)

      :force_finalize ->
        state = persist_assistant(state, assistant_msg)
        Lifecycle.finalize_turn(state)

      :overflow_tool_calls ->
        handle_overflow_tool_calls(response, state, assistant_msg)

      :normal_tool_calls ->
        handle_normal_tool_calls(response, state, assistant_msg)

      :empty_assistant ->
        # A provider response with no text, thinking, refusal, or tool
        # call at all would persist a zero-part assistant message. Never
        # do that: surface it as a non-empty error (broadcast BEFORE the
        # idle status) and end the turn.
        state =
          LLMStreamHandler.llm_error_state(
            "The model returned a response with no content.",
            state
          )

        Lifecycle.finalize_turn(state)

      :truncated ->
        state = persist_assistant(state, assistant_msg)
        handle_truncated_response(state)

      :silent ->
        state = persist_assistant(state, assistant_msg)
        handle_silent_response(state)

      :finalize ->
        state = persist_assistant(state, assistant_msg)
        Lifecycle.finalize_turn(state)
    end
  end

  # Build the classification input for `Machine.Turn.classify_response/1`
  # from the response + turn state. Extracted so `dispatch_response/3`
  # stays within credo's ABC limit.
  defp classify(response, state, assistant_msg) do
    Turn.classify_response(%{
      compactor?: compactor_entry?(state),
      force_finalize: turn(state).force_finalize,
      has_tool_calls: RunResponse.has_tool_calls?(response),
      iteration: turn(state).iteration,
      max_iterations: turn(state).max_iterations,
      empty_assistant?: empty_assistant?(assistant_msg),
      truncated?: RunResponse.truncated?(response),
      silent?: silent_response?(response)
    })
  end

  defp empty_assistant?({:assistant, %Assistant{parts: parts}}), do: parts == []

  defp persist_assistant(state, {:assistant, msg}) do
    {:noreply, state} = LLMStreamHandler.tool_calls_received(msg, state)
    state
  end

  defp silent_response?(response) do
    not has_visible_text?(response.text) and not has_visible_text?(response.refusal)
  end

  defp has_visible_text?(nil), do: false
  defp has_visible_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp has_visible_text?(_), do: false

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
    case append_user_nudge(state, nudge_text) do
      {:ok, state} ->
        send(self(), :iterate)
        {:noreply, state}

      :no_room ->
        Lifecycle.finalize_turn(state)
    end
  end

  defp count_prior_nudges(state), do: count_prior_messages(state, @empty_nudges)

  defp count_prior_messages(state, texts) do
    state.chat_state.messages
    |> Enum.count(fn
      {:user, %{parts: [%Part.Text{text: text}]}} when is_binary(text) ->
        text in texts

      _ ->
        false
    end)
  end

  defp append_user_nudge(state, text) do
    if nudge_over_budget?(state, text) do
      :no_room
    else
      user_message = ContextReminder.build_user_notice(text, nil)
      {_stamped, state} = MessageAppender.handle_single(state, user_message)
      {:ok, state}
    end
  end

  defp nudge_over_budget?(state, text) do
    limit = turn(state).ctx.context_limit

    if is_integer(limit) and limit > 0 do
      Budget.remaining(state.chat_state.messages, limit) < TokensEstimator.estimate(text)
    else
      false
    end
  end

  defp compactor_entry?(state), do: match?({:compaction, _, _}, state.live.machine.entry)

  defp defer_response?(response, state, assistant_msg) do
    not compactor_entry?(state) and
      not turn(state).force_finalize and
      not RunResponse.has_tool_calls?(response) and
      not RunResponse.truncated?(response) and
      not silent_response?(response) and
      over_budget?(assistant_msg, turn(state).ctx.context_limit)
  end

  defp over_budget?(assistant_msg, limit), do: not Budget.fits?([assistant_msg], limit)

  defp defer_response(state, assistant_msg) do
    continuation = {
      :assistant_response,
      assistant_msg,
      turn(state).iteration,
      turn(state).max_iterations
    }

    send(self(), {:needs_compaction, self(), continuation})

    Logger.info(
      "Turn: emitting :needs_compaction with :assistant_response continuation " <>
        "(iter=#{turn(state).iteration}, max=#{turn(state).max_iterations})"
    )

    {:noreply, state}
  end

  defp handle_overflow_tool_calls(response, state, assistant_msg) do
    state = persist_assistant(state, assistant_msg)
    tool_msg = Messages.synthetic_error_tool_results(response)
    {_stamped, state} = MessageAppender.handle_single(state, tool_msg)
    state = put_force_finalize(state, true)
    send(self(), :iterate)
    {:noreply, state}
  end

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

  defp handle_compact_only(response, state, assistant_msg) do
    tool_call = hd(response.tool_calls)
    pre_count = TokensEstimator.estimate_messages(turn(state).ctx.messages || [])
    synthetic_result = build_synthetic_compact_result(tool_call, pre_count)

    continuation = {
      :compact_tool,
      [assistant_msg, synthetic_result],
      turn(state).iteration,
      turn(state).max_iterations
    }

    send(self(), {:needs_compaction, self(), continuation})

    Logger.info(
      "Turn: emitting :needs_compaction with :compact_tool continuation " <>
        "(iter=#{turn(state).iteration}, max=#{turn(state).max_iterations})"
    )

    {:noreply, state}
  end

  defp refuse_compact_mixed(response, state, assistant_msg) do
    state = persist_assistant(state, assistant_msg)

    tool_msg =
      Messages.refuse_context_compact_co_batch(
        response.tool_calls,
        turn(state).ctx.messages || []
      )

    {_stamped, state} = MessageAppender.handle_single(state, tool_msg)
    state = put_force_finalize(state, true)
    send(self(), :iterate)
    {:noreply, state}
  end

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

  defp handle_regular_tool_calls(response, state, assistant_msg) do
    case post_response_preflight(response.tool_calls, state, assistant_msg) do
      :fits ->
        state = persist_assistant(state, assistant_msg)
        Iteration.spawn_tool_worker(state, response.tool_calls)

      {:refuse, _reason} ->
        continuation = {
          :tool_call,
          assistant_msg,
          turn(state).iteration,
          turn(state).max_iterations
        }

        send(self(), {:needs_compaction, self(), continuation})

        Logger.info(
          "Turn: emitting :needs_compaction with :tool_call continuation " <>
            "(iter=#{turn(state).iteration}, max=#{turn(state).max_iterations})"
        )

        {:noreply, state}
    end
  end

  defp post_response_preflight(tool_calls, state, assistant_msg) do
    messages = state.chat_state.messages
    ctx = %{turn(state).ctx | messages: messages ++ [assistant_msg]}
    BatchSizer.preflight(tool_calls, ctx)
  end

  # --- turn accessors ---

  defp turn(state), do: state.live.machine.work

  defp clear_worker(state) do
    update_work(state, &%{&1 | active_worker: nil, active_worker_kind: nil})
  end

  defp put_force_finalize(state, value) do
    update_work(state, &%{&1 | force_finalize: value})
  end

  defp active_index(state), do: turn(state).active_message_index

  defp advance_active_index(state, n) do
    update_work(state, &%{&1 | active_message_index: &1.active_message_index + n})
  end

  defp update_work(state, fun) do
    machine = state.live.machine
    %{state | live: %{state.live | machine: %{machine | work: fun.(machine.work)}}}
  end
end
