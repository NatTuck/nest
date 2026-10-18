defmodule Nest.Agents.Agent.Machine.Response do
  @moduledoc """
  Pure chat-response decision logic for `Machine.step/2`.

  When an HTTP response lands in `:generating`/`:chat`, the machine must
  decide whether this is a final reply, a tool batch, a deferral for
  compaction, an overflow, a truncation, or a silent nudge. All of that
  is pure: this module builds the assistant message, the synthetic notice
  and nudge content, the API log, and the continuation, then returns the
  actions the executor runs. No effects happen here.

  A final reply is also where the reply obligation is checked (issue #31
  §1.5): while the agent still owes a peer an answer, the runtime injects
  one reminder and continues the turn instead of settling.

  Rooted in `Machine.Turn.classify_response/1` so the decision table
  has one home.
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.ReplyReminder
  alias Nest.Agents.Agent.Machine.Turn, as: ResponseClassifier
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Messages
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Header
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Scripts.CompactionProbeSupport
  alias Nest.Tokens.Budget
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Estimator

  @max_empty_retries 2

  # The `context-compact` `cover` argument limit. A longer `cover` is an agent
  # writing the summary into the request instead of using `preserve`, so it is
  # refused rather than truncated. The number itself lives with the tool schema
  # (`Nest.Tools`), so what the model is told and what is enforced cannot drift.
  @max_cover_length Nest.Tools.context_compact_cover_limit()

  # The refusal a legacy `focus` argument gets. It has to teach the replacement
  # in full: the caller holding this argument is running the tool schema from
  # before the split, so it cannot see the new descriptions, and this message is
  # the only place the new contract can reach it.
  @legacy_focus_reason "`focus` no longer exists. Pass `cover` (short guidance, at most " <>
                         "100 characters, naming what the summary must cover) and/or " <>
                         "`preserve` (literal content to carry into the summary message " <>
                         "verbatim) instead."

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

  # The compactor's response, committed.
  #
  # Unreachable today: `classify_response/1` answers `:compaction` only when the
  # machine carries a `{:compaction, …}` entry, and `Phase.enter/4` clears that
  # entry on the way out of a compaction turn, so a chat-kind machine never
  # holds one. It stays because the routing contract is written against it —
  # `Phase`'s `turn_entry/3` comment names this pairing as the hazard it guards
  # — and it commits through `Compaction.commit_data/2` so this copy cannot
  # drift from the live path's, which is exactly how it lost `:preserve`.
  defp branch(:compaction, m, response, _assistant_msg, base) do
    {data, _sequences} = Compaction.commit_data(m, response)

    {:ok, base ++ [{:commit_compaction, data}], Phase.enter(m, :compaction, :committing)}
  end

  defp branch(:force_finalize, m, _response, assistant_msg, base) do
    finalize_or_defer(m, assistant_msg, base, [{:finalize, :clean}, {:drain_inbox}])
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
    msg = "The model returned a response with no content."
    Phase.rest(m, :chat, :empty_assistant, base ++ [{:llm_error, msg}, {:drain_inbox}])
  end

  defp branch(kind, m, _response, assistant_msg, base) when kind in [:truncated, :silent] do
    case reprompt_decision(m, kind) do
      {:reprompt, nudge} ->
        nudge_msg = ContextReminder.build_user_notice(nudge, m.work.ctx.mode)
        machine = Phase.enter(m, :chat, :generating, :http)
        {:ok, base ++ [{:append, assistant_msg}, {:append, nudge_msg}, :iterate], machine}

      :finalize ->
        warning = finalize_warning(kind)

        finalize_or_defer(m, assistant_msg, base, [
          {:log, :warning, warning},
          {:finalize, :clean},
          {:drain_inbox}
        ])
    end
  end

  defp branch(:finalize, m, _response, assistant_msg, base) do
    # A final text reply is not tool execution: append the assistant and
    # go straight to idle (same shape as a forced finalize).
    finalize_or_defer(m, assistant_msg, base, [{:finalize, :clean}, {:drain_inbox}])
  end

  # Append a final assistant reply, or — when persisting it would spend the
  # compaction reserve (`size(M + reply) + C > L`) — carry it across a
  # compaction as `{:assistant_response, msg, iter, max}`. The reply was
  # produced against the pre-compaction context, so it is not part of the
  # compaction request; `Machine.Compaction.resume/1` commits it active-side
  # after the summary and finalizes. `tail` runs after the append in the
  # fits branch (e.g. a finalize warning log).
  defp finalize_or_defer(m, assistant_msg, base, tail) do
    if reply_fits?(m, assistant_msg) do
      case ReplyReminder.decision(m, m.work.ctx.messages ++ [assistant_msg]) do
        {:remind, text, m} ->
          # The gate (issue #31 §1.5): the turn is NOT over — the agent still
          # owes a peer a reply — so the reminder is appended and the turn
          # continues. The phase is entered as `:generating`/`:http`, exactly
          # like the truncation/silent re-prompt above: entering `:idle` would
          # broadcast the transient idle that #15 exists to prevent, and an
          # idle peer is by construction one with no unpaid debt.
          #
          # The reminder is a synthetic user message, and its header says so:
          # `[From nest runtime | mode: …]`, because the runtime is not a peer
          # and the row must not read as one.
          reminder = ContextReminder.build_user_notice(text, m.work.ctx.mode)
          machine = Phase.enter(m, :chat, :generating, :http)
          {:ok, base ++ [{:append, assistant_msg}, {:append, reminder}, :iterate], machine}

        :settle ->
          settle(m, assistant_msg, base, tail)
      end
    else
      continuation =
        {:assistant_response, assistant_msg, m.work.iteration, m.work.max_iterations}

      {:ok, actions, machine} = Compaction.stage(m, continuation)
      {:ok, base ++ actions, machine}
    end
  end

  defp settle(m, assistant_msg, base, tail) do
    Phase.rest(m, :chat, :no_reminder, base ++ [{:append, assistant_msg} | tail])
  end

  defp reply_fits?(m, assistant_msg) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      Budget.fits?(m.work.ctx.messages ++ [assistant_msg], limit)
    else
      true
    end
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

  # A `context-compact` call: validate its arguments, persist the call and its
  # synthetic result, then stage the compaction.
  #
  # The call is an ordinary action of the turn that is about to be archived, so
  # both rows are persisted *before* the request row. The archive then holds
  # the whole causal chain (call, result, bridge ack, request, summary), and
  # the pair never has to be replayed into the new segment — which is what put
  # the call on the wrong side of the marker. The carried entry therefore
  # carries no messages: the only thing left to carry is the intent to resume
  # generation, and the entry has to say so, because a `nil` carried entry
  # appends the idle bridge ack (a segment ending on an assistant is not a
  # valid generation request).
  #
  # The arguments are *not* copied into the request. The compactor reads them
  # from the persisted call immediately before the request, so
  # `Dispatch.compaction_plan/1` only names them — see
  # `CompactionProbeSupport.compaction_mention/0`.
  defp compact_only(m, response, assistant_msg, base) do
    [tool_call] = response.tool_calls

    case compact_arguments(tool_call) do
      {:ok, preserve} ->
        synthetic = build_synthetic_compact_result(tool_call)
        continuation = {:compact_resume, m.work.iteration, m.work.max_iterations}

        # The request *names* the call's arguments instead of repeating them —
        # they are in the conversation, one message back — so the tool path's
        # guidance is the constant clause that says how to treat them. The
        # other source of `focus` is an operator's `/compact <focus>` text
        # (`Transitions`'s `{:compact_request, focus}`), and a compaction has
        # one source or the other, never both.
        work = %{
          m.work
          | focus: CompactionProbeSupport.compaction_mention(),
            preserve: preserve
        }

        {:ok, actions, machine} = Compaction.stage(%{m | work: work}, continuation)
        {:ok, base ++ [{:append, assistant_msg}, {:append, synthetic}] ++ actions, machine}

      {:refuse, reason} ->
        tool_msg = Messages.refuse_context_compact_arguments(response.tool_calls, reason)
        machine = Phase.enter(m, :chat, :generating, :http)
        {:ok, base ++ [{:append, assistant_msg}, {:append, tool_msg}, :iterate], machine}
    end
  end

  # The `context-compact` tool's arguments, validated against an allowlist.
  # Returns the `preserve` text (nil when absent or blank) or the refusal
  # reason.
  #
  # `cover` is guidance the compactor reads from the call itself, so the only
  # thing to enforce is its size: a long `cover` is an agent writing the
  # summary into the request, which is what `preserve` is for, and silently
  # truncating it would drop whatever the agent thought it said. `preserve` is
  # content, so any length is allowed; it rides `work.preserve` into the
  # summary message.
  #
  # Anything the allowlist does not name is refused rather than ignored, because
  # ignoring it stages a compaction without the content the caller meant to
  # keep — silently, which is the loss this contract exists to prevent. Two
  # cases are worth naming:
  #
  #   * `focus`, the argument the split removed, gets its own message: the
  #     caller holding it is running the schema from before the split (a
  #     running agent keeps the tool list it was started with until a workspace
  #     change or a compaction), so that message is the only place the new
  #     contract can reach it;
  #   * a near-miss a model invents (`preserve_text`) is refused too, which is
  #     what makes the refusal a rule rather than one exception.
  #
  # JSON-decoded arguments arrive with string keys, and a present value of the
  # wrong type is refused for the same reason an unknown key is. One case this
  # cannot cover: `Streaming` maps an arguments JSON decode error to `%{}`,
  # which is indistinguishable here from a bare `context-compact` call — and a
  # bare call is legitimate, since both arguments are optional. That failure is
  # reported where it happens.
  defp compact_arguments(%ToolCall{arguments: args}) when is_map(args) do
    cond do
      Map.has_key?(args, "focus") ->
        {:refuse, @legacy_focus_reason}

      unknown_arguments(args) != [] ->
        {:refuse, unknown_arguments_reason(args)}

      true ->
        with :ok <- cover_verdict(Map.get(args, "cover")),
             :ok <- preserve_verdict(Map.get(args, "preserve")) do
          {:ok, blank_to_nil(Map.get(args, "preserve"))}
        end
    end
  end

  defp compact_arguments(_tool_call), do: {:ok, nil}

  @compact_argument_names ~w(cover preserve)

  defp unknown_arguments(args) do
    args
    |> Map.keys()
    |> Enum.reject(&(&1 in @compact_argument_names))
    |> Enum.sort()
  end

  defp unknown_arguments_reason(args) do
    "unknown argument(s) #{Enum.map_join(unknown_arguments(args), ", ", &inspect/1)}: " <>
      "context-compact takes `cover` (short guidance for the summary) and `preserve` " <>
      "(content to carry into it verbatim). Unknown arguments are refused rather than " <>
      "ignored, because ignoring one would silently drop what it carried."
  end

  defp cover_verdict(nil), do: :ok
  defp cover_verdict(""), do: :ok

  defp cover_verdict(cover) when is_binary(cover) do
    if String.length(cover) > @max_cover_length do
      {:refuse,
       "`cover` is #{String.length(cover)} characters, over the " <>
         "#{@max_cover_length}-character limit. Keep `cover` to a short " <>
         "description of what the summary must cover, and put literal content " <>
         "you want carried into the summary in `preserve`."}
    else
      :ok
    end
  end

  defp cover_verdict(other), do: {:refuse, "`cover` must be a string, got #{inspect(other)}"}

  defp preserve_verdict(preserve) when is_binary(preserve), do: :ok
  defp preserve_verdict(nil), do: :ok

  defp preserve_verdict(other),
    do: {:refuse, "`preserve` must be a string, got #{inspect(other)}"}

  # Blank *or whitespace-only*: a `preserve` of `"   "` would otherwise render
  # as an empty section between two separators, and the summary body's
  # treatment of a blank `preserve` (see `Turn.Commit.summary_body/4`) would
  # not hold for it.
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
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

  # The synthetic result of a `context-compact` call: a successful tool result
  # persisted with the call, before the compaction runs. It says what is true
  # when it is written — the compaction is starting — rather than reporting an
  # outcome the compaction has not produced yet. A later failure surfaces
  # through the `:compaction_failed` state and its banner, and the request row
  # it answers stays in the transcript either way.
  defp build_synthetic_compact_result(tool_call) do
    {:tool,
     %Tool{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [
         %Part.ToolResult{
           tool_call_id: tool_call.id,
           name: "context-compact",
           arguments: tool_call.arguments,
           content: "Compacting now.",
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

  # --- notice plan (pure) ---

  defp notice_plan(m, response) do
    messages = m.work.ctx.messages
    # One projection per response, shared by the notice spec and the threshold
    # bookkeeping below. Each projection batches a `stat` of every `file-read`
    # target (issue #48), so deriving it twice would double that cost for the
    # same answer.
    projected = projection_or_nil(m, response, messages)
    specs = collect_specs(m, projected)

    {actions, _msgs} = inject_specs(specs, m, messages)
    {crossed, projection} = context_bookkeeping(m, projected)

    actions = actions ++ crossed_actions(m, crossed) ++ projection_actions(projection)
    {actions, maybe_clear_pending(m, specs)}
  end

  # The projection only means something with a usable limit: below it there is
  # nothing to compare against (and `BatchSizer.preflight/2` has no clause for
  # a nil or zero limit), so every consumer skips.
  defp projection_or_nil(m, response, messages) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      projected_tokens_for_response(m, response, messages)
    end
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

  defp collect_specs(m, projected) do
    # `pending_notice` is the budget reminder's slot (a binary, from
    # `do_dispatch_http/1`). A space-environment change no longer uses it: it
    # rides the `:workspace_notice` event and, when it needs a compaction, that
    # compaction's entry (`Compaction.stage/3`).
    budget =
      if is_binary(m.work.pending_notice),
        do: BudgetReminder.spec_from_pending(m.work.pending_notice)

    context = compute_context_spec(m, projected)

    # Every spec carries the mode its notice row will state: the recipient's,
    # exactly as the row's own header and metadata do.
    [budget, context]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.put(&1, :mode, m.work.ctx.mode))
  end

  defp compute_context_spec(m, projected) do
    limit = m.work.ctx.context_limit

    if not is_integer(limit) or limit <= 0 do
      nil
    else
      crossed = m.work.ctx.crossed_thresholds
      compact? = ContextReminder.compact_available?(m.work.ctx.tools)
      ContextReminder.spec(projected, limit, crossed, compact?)
    end
  end

  defp context_bookkeeping(m, projected) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      crossed = m.work.ctx.crossed_thresholds

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
      # The pair is `[assistant(attention), user(header + notice)]`, so the
      # header the injector adds is part of what it costs.
      pair_size =
        Estimator.estimate(spec.attention) +
          Estimator.estimate(Header.put(spec.notice, :runtime, spec.mode))

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
          {:fits, projected} -> projected
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

  # Counts how many of `texts` the transcript already carries. The nudges are
  # persisted behind the runtime's header, so the comparison is against the
  # *body*: the header's mode clause is the mode the row was written under, and
  # this bound counts what was appended, not what was appended under the current
  # mode. Comparing headered text made the count mode-dependent, which reset it
  # on a turn that changed the mode and gave a pathological model a second run of
  # re-prompts.
  defp count_prior(messages, texts) do
    Enum.count(messages, fn
      {:user, %{parts: [%Part.Text{text: text}]}} when is_binary(text) ->
        Header.runtime?(text) and Header.body(text) in texts

      _ ->
        false
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
