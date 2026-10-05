defmodule Nest.Agents.Agent.Machine.Response do
  @moduledoc """
  Pure chat-response decision logic for `Machine.step/2`.

  When an HTTP response lands in `:generating`/`:chat`, the machine must
  decide whether this is a final reply, a tool batch, a deferral for
  compaction, an overflow, a truncation, or a silent nudge. All of that
  is pure: this module builds the assistant message, the synthetic notice
  and nudge content, the API log, and the continuation, then returns the
  actions the executor runs. No effects happen here.

  Extracted from the old `Turn.ResponseHandler` and rooted in
  `Machine.Turn.classify_response/1` so the decision table has one home.
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.Turn, as: ResponseClassifier
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Messages
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Tokens.Budget
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Estimator

  @max_empty_retries 2

  @empty_nudges [
    "You gave an empty response, which you shouldn't do. What were you saying?",
    "You did it again — another empty response with no actual text. " <>
      "Write out your real reply as text now."
  ]

  @max_truncation_retries 2

  @truncation_nudge "Keep going. Your previous response hit the output token limit — " <>
                      "continue exactly where you left off, and don't repeat what you already wrote."

  @doc "Filter `Part.ToolUse` parts into `ToolCall` structs."
  @spec tool_calls_from_parts([Part.t()]) :: [ToolCall.t()]
  def tool_calls_from_parts(parts) do
    parts
    |> Enum.filter(&match?(%Part.ToolUse{}, &1))
    |> Enum.map(fn %Part.ToolUse{id: id, name: name, arguments: arguments} ->
      %ToolCall{id: id, name: name, arguments: arguments || %{}}
    end)
  end

  @doc "Build the assistant message and its API log entry from a response."
  @spec assistant_with_log(Machine.t(), RunResponse.t()) :: {{:assistant, Assistant.t()}, map()}
  def assistant_with_log(m, response) do
    {role, msg} = Messages.assistant(response)
    index = m.work.active_message_index
    payload = Broadcasts.api_response_from_run(response)
    {id, sequences} = Broadcasts.next_api_log_id(index, m.work.ctx.api_log_sequences)

    log = %{id: id, timestamp: DateTime.utc_now(), type: :response, payload: payload}
    {{role, %{msg | api_logs: [log]}}, sequences}
  end

  @doc "Dispatch an HTTP response in the chat `:generating` phase."
  @spec dispatch(Machine.t(), RunResponse.t()) :: {:ok, [term()], Machine.t()}
  def dispatch(m, response) do
    compactor? = match?({:compaction, _, _}, m.entry)
    {assistant_msg, sequences} = assistant_with_log(m, response)

    {notice_actions, m} =
      if compactor?, do: {[], m}, else: notice_plan(m, response)

    base =
      [{:merge_metrics, response.usage}, {:set_api_log_sequences, sequences}] ++ notice_actions

    decision = classify(m, response, assistant_msg)
    branch(decision, m, response, assistant_msg, base)
  end

  # --- branches ---

  defp branch(:compaction, m, _response, assistant_msg, base) do
    {:compaction, staged, carried_entry} = m.entry

    data = %{
      summary_text: assistant_text(assistant_msg),
      staged: staged,
      summary_assistant: assistant_msg,
      carried_entry: carried_entry
    }

    {:ok, base ++ [{:commit_compaction, data}], Phase.enter(m, :compaction, :committing)}
  end

  defp branch(:force_finalize, m, _response, assistant_msg, base) do
    machine = Phase.enter(m, :chat, :idle)
    {:ok, base ++ [{:append, assistant_msg}, {:finalize, :clean}, {:drain_inbox}], machine}
  end

  defp branch(:overflow_tool_calls, m, response, assistant_msg, base) do
    tool_msg = Messages.synthetic_error_tool_results(response)
    machine = force_finalize(m)
    {:ok, base ++ [{:append, assistant_msg}, {:append, tool_msg}, :iterate], machine}
  end

  defp branch(:normal_tool_calls, m, response, assistant_msg, base) do
    cond do
      compact_only?(response.tool_calls) -> compact_only(m, response, assistant_msg, base)
      contains_compact?(response.tool_calls) -> refuse_mixed(m, response, assistant_msg, base)
      true -> regular(m, response, assistant_msg, base)
    end
  end

  defp branch(:empty_assistant, m, _response, _assistant_msg, base) do
    machine = Phase.enter(m, :chat, :idle)
    msg = "The model returned a response with no content."
    {:ok, base ++ [{:llm_error, msg}, {:drain_inbox}], machine}
  end

  defp branch(kind, m, _response, assistant_msg, base) when kind in [:truncated, :silent] do
    case reprompt_decision(m, kind) do
      {:reprompt, nudge} ->
        nudge_msg = ContextReminder.build_user_notice(nudge, nil)
        machine = Phase.enter(m, :chat, :generating, :http)
        {:ok, base ++ [{:append, assistant_msg}, {:append, nudge_msg}, :iterate], machine}

      :finalize ->
        machine = Phase.enter(m, :chat, :idle)
        warning = finalize_warning(kind)

        {:ok,
         base ++
           [
             {:append, assistant_msg},
             {:log, :warning, warning},
             {:finalize, :clean},
             {:drain_inbox}
           ], machine}
    end
  end

  defp branch(:finalize, m, _response, assistant_msg, base) do
    # Persist the final assistant while in `:executing_tools` so the
    # status announcement matches the legacy persist path, then finalize.
    machine = Phase.enter(m, :chat, :executing_tools, :tools)
    {:ok, base ++ [{:append, assistant_msg}, :finalize_idle], machine}
  end

  defp finalize_warning(:silent),
    do:
      "Empty assistant response finalized after #{@max_empty_retries} re-prompt(s): " <>
        "no text or refusal content"

  defp finalize_warning(:truncated),
    do:
      "Truncated assistant response finalized after #{@max_truncation_retries} " <>
        "keep-going re-prompt(s)"

  # --- tool-call branches ---

  defp compact_only(m, response, assistant_msg, base) do
    [tool_call] = response.tool_calls
    pre_count = Estimator.estimate_messages(m.work.ctx.messages || [])
    synthetic = build_synthetic_compact_result(tool_call, pre_count)

    continuation =
      {:compact_tool, [assistant_msg, synthetic], m.work.iteration, m.work.max_iterations}

    {:ok, actions, machine} = Compaction.stage(m, continuation, nil)
    {:ok, base ++ actions, machine}
  end

  defp refuse_mixed(m, response, assistant_msg, base) do
    tool_msg =
      Messages.refuse_context_compact_co_batch(response.tool_calls, m.work.ctx.messages || [])

    machine = force_finalize(m)
    {:ok, base ++ [{:append, assistant_msg}, {:append, tool_msg}, :iterate], machine}
  end

  defp regular(m, response, assistant_msg, base) do
    calls = response.tool_calls
    continuation = {:tool_call, assistant_msg, m.work.iteration, m.work.max_iterations}
    projected = m.work.ctx.messages ++ [assistant_msg]
    ctx = %{m.work.ctx | messages: projected}
    machine = %{m | work: %{m.work | preflight: %{calls: calls, continuation: continuation}}}
    machine = Phase.enter(machine, :chat, :generating, :http)
    {:ok, base ++ [{:append, assistant_msg}, {:preflight, ctx, calls, continuation}], machine}
  end

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

  # --- classification ---

  defp classify(m, response, assistant_msg) do
    ResponseClassifier.classify_response(%{
      compactor?: match?({:compaction, _, _}, m.entry),
      force_finalize: m.work.force_finalize,
      has_tool_calls: RunResponse.has_tool_calls?(response),
      iteration: m.work.iteration,
      max_iterations: m.work.max_iterations,
      empty_assistant?: empty_assistant?(assistant_msg),
      truncated?: RunResponse.truncated?(response),
      silent?: silent_response?(response)
    })
  end

  defp empty_assistant?({:assistant, %Assistant{parts: parts}}), do: parts == []

  defp silent_response?(response) do
    not has_visible_text?(response.text) and not has_visible_text?(response.refusal)
  end

  defp has_visible_text?(nil), do: false
  defp has_visible_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp has_visible_text?(_), do: false

  defp assistant_text({:assistant, %Assistant{parts: parts}}) do
    parts
    |> Enum.map_join("", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end

  # --- notice plan (pure) ---

  defp notice_plan(m, response) do
    messages = m.work.ctx.messages
    specs = collect_specs(m, response, messages)

    {actions, _msgs} = inject_specs(specs, m, messages)
    {crossed, projection} = context_bookkeeping(m, response, messages)

    actions = actions ++ crossed_actions(m, crossed) ++ projection_actions(projection)
    {actions, maybe_clear_pending(m, specs)}
  end

  defp inject_specs(specs, m, messages) do
    Enum.reduce(specs, {[], messages}, fn spec, {acc, msgs} -> inject_spec(spec, m, acc, msgs) end)
  end

  defp inject_spec(spec, m, acc, msgs) do
    if notice_over_budget?(m, spec, msgs) do
      {acc, msgs}
    else
      append_pair(spec, acc, msgs)
    end
  end

  defp append_pair(spec, acc, msgs) do
    case NoticePairInjector.build_pair(msgs, spec, :agent_user) do
      {:ok, pair} -> {acc ++ [{:append_many, pair}], msgs ++ pair}
      :deferred -> {acc, msgs}
    end
  end

  defp crossed_actions(m, crossed) do
    if MapSet.equal?(crossed, m.work.ctx.crossed_thresholds),
      do: [],
      else: [{:set_crossed_thresholds, crossed}]
  end

  defp projection_actions(projection) do
    if is_integer(projection), do: [{:set_context_projection, projection}], else: []
  end

  defp maybe_clear_pending(m, specs) do
    if Enum.any?(specs, &(&1.kind == :budget)),
      do: %{m | work: %{m.work | pending_notice: nil}},
      else: m
  end

  defp collect_specs(m, response, messages) do
    budget =
      if m.work.pending_notice, do: BudgetReminder.spec_from_pending(m.work.pending_notice)

    context = compute_context_spec(m, response, messages)

    [budget, context] |> Enum.reject(&is_nil/1)
  end

  defp compute_context_spec(m, response, messages) do
    limit = m.work.ctx.context_limit

    if not is_integer(limit) or limit <= 0 do
      nil
    else
      crossed = m.work.ctx.crossed_thresholds
      projected = projected_tokens_for_response(m, response, messages)
      compact? = ContextReminder.compact_available?(m.work.ctx.tools)
      ContextReminder.spec(projected, limit, crossed, compact?)
    end
  end

  defp context_bookkeeping(m, response, messages) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      crossed = m.work.ctx.crossed_thresholds
      projected = projected_tokens_for_response(m, response, messages)

      crossed =
        case ContextReminder.highest_unannounced(projected, limit, crossed) do
          nil -> crossed
          atom -> MapSet.put(crossed, atom)
        end

      {crossed, projected}
    else
      {m.work.ctx.crossed_thresholds, nil}
    end
  end

  defp notice_over_budget?(m, spec, messages) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      pair_size = Estimator.estimate(spec.attention) + Estimator.estimate(spec.notice)
      Budget.remaining(messages, limit) < pair_size
    else
      false
    end
  end

  defp projected_tokens_for_response(m, response, messages) do
    ctx = %{m.work.ctx | messages: messages}

    case response.tool_calls do
      nil ->
        projected_text(messages, response)

      [] ->
        projected_text(messages, response)

      tool_calls ->
        case BatchSizer.preflight(tool_calls, ctx) do
          :fits -> BatchSizer.projected_content_size(tool_calls, ctx)
          {:refuse, _reason} -> ctx.context_limit
        end
    end
  end

  defp projected_text(messages, response) do
    ConversationSize.size(messages) + Estimator.estimate(response.text || "") + 10
  end

  # --- nudges ---

  defp reprompt_decision(m, :silent) do
    nudges = count_prior(m.work.ctx.messages, @empty_nudges)

    if nudges < @max_empty_retries do
      nudge_or_finalize(m, Enum.at(@empty_nudges, nudges))
    else
      :finalize
    end
  end

  defp reprompt_decision(m, :truncated) do
    if count_prior(m.work.ctx.messages, [@truncation_nudge]) < @max_truncation_retries do
      nudge_or_finalize(m, @truncation_nudge)
    else
      :finalize
    end
  end

  defp nudge_or_finalize(m, text) do
    limit = m.work.ctx.context_limit

    over_budget? =
      is_integer(limit) and limit > 0 and
        Budget.remaining(m.work.ctx.messages, limit) < Estimator.estimate(text)

    if over_budget?, do: :finalize, else: {:reprompt, text}
  end

  defp count_prior(messages, texts) do
    Enum.count(messages, fn
      {:user, %{parts: [%Part.Text{text: text}]}} when is_binary(text) -> text in texts
      _ -> false
    end)
  end

  # Only concrete `ToolCall` structs are special-cased; wire-format maps
  # from some test/mock clients flow through the regular tool path (matching
  # the pre-refactor behavior).
  defp compact_only?([%ToolCall{name: "context-compact"}]), do: true
  defp compact_only?(_), do: false

  defp contains_compact?(tool_calls) do
    Enum.any?(tool_calls, fn
      %ToolCall{name: "context-compact"} -> true
      _ -> false
    end)
  end

  defp force_finalize(m) do
    Phase.enter(%{m | work: %{m.work | force_finalize: true}}, :chat, :generating, :http)
  end
end
