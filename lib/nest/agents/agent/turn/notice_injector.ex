defmodule Nest.Agents.Agent.Turn.NoticeInjector do
  @moduledoc """
  Case 2 notice injection at the LLM-response-construction site.

  Each trigger source (budget reminder, context-usage threshold)
  produces a `%{kind, attention, notice}` spec, and this module
  collects them and injects each as a synthetic
  `[assistant(attention), user(notice)]` pair before the LLM's
  response.

  The driver runs in the Agent process, so the projection reads
  `state.chat_state.messages` / `state.live.crossed_thresholds`
  directly and the injected bookkeeping is written straight to
  `state.live` — no GenServer round-trips.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.LLM.RunResponse
  alias Nest.Tokens.Budget
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Estimator, as: TokensEstimator

  require Logger

  @doc """
  Collect notice specs from all trigger sources.

  Returns a list of specs (possibly empty, possibly of length 1 or
  2). The order of the list is the injection order (budget first).
  """
  @spec collect_case2_specs(RunResponse.t(), Agent.t()) :: [ContextReminder.spec()]
  def collect_case2_specs(response, state) do
    collect_specs(response, state, state.chat_state.messages)
  end

  defp collect_specs(response, state, messages) do
    pending = state.live.machine.work.pending_notice

    budget =
      if pending, do: BudgetReminder.spec_from_pending(pending)

    context = compute_context_spec(response, state, messages)

    [budget, context] |> Enum.reject(&is_nil/1)
  end

  @doc """
  Collect specs, inject each, update bookkeeping, and return
  `{appended, state}` where `appended` is the number of messages
  actually appended (a skipped or deferred spec contributes 0, so the
  caller advances `active_message_index` by exactly what landed).
  """
  @spec inject_all(RunResponse.t(), Agent.t()) :: {non_neg_integer(), Agent.t()}
  def inject_all(response, state) do
    messages = state.chat_state.messages
    specs = collect_specs(response, state, messages)
    {appended, state} = inject_specs(specs, state, messages)

    state =
      if Enum.any?(specs, &(&1.kind == :budget)) do
        put_pending_notice(state, nil)
      else
        state
      end

    _ = update_crossed_thresholds_for_context(response, state, messages)

    {appended, state}
  end

  defp compute_context_spec(response, state, messages) do
    ctx = state.live.machine.work.ctx
    limit = ctx.context_limit

    if not is_integer(limit) or limit <= 0 do
      nil
    else
      crossed = state.live.crossed_thresholds
      projected = projected_tokens_for_response(response, state, messages)
      compact? = ContextReminder.compact_available?(ctx.tools)
      ContextReminder.spec(projected, limit, crossed, compact?)
    end
  end

  # Update `live.crossed_thresholds` / `live.context_projection` after a
  # context spec has been injected.
  defp update_crossed_thresholds_for_context(response, state, messages) do
    ctx = state.live.machine.work.ctx
    limit = ctx.context_limit

    if is_integer(limit) and limit > 0 do
      crossed = state.live.crossed_thresholds
      projected = projected_tokens_for_response(response, state, messages)

      state = put_context_projection(state, projected)

      case ContextReminder.highest_unannounced(projected, limit, crossed) do
        nil ->
          state

        atom ->
          put_crossed_thresholds(state, MapSet.put(crossed, atom))
      end
    else
      state
    end
  end

  defp inject_specs([], state, _messages), do: {0, state}

  defp inject_specs([spec | rest], state, messages) do
    {count, state} = inject_one_spec(spec, state, messages)
    {more, state} = inject_specs(rest, state, messages)
    {count + more, state}
  end

  defp inject_one_spec(spec, state, messages) do
    if notice_over_budget?(spec, state, messages) do
      Logger.warning(
        "NoticeInjector: skipping #{spec.kind} notice; no room within the compaction reserve"
      )

      {0, state}
    else
      case NoticePairInjector.inject_pair_in_process(messages, state, spec, :agent_user) do
        {:ok, _shape, stamped, new_state} -> {length(stamped), new_state}
        :deferred -> {0, state}
        :agent_dead -> {0, state}
      end
    end
  end

  # Synthetic notices are ordinary content: they must never spend the
  # compaction reserve.
  defp notice_over_budget?(spec, state, messages) do
    limit = state.live.machine.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      pair_size =
        TokensEstimator.estimate(spec.attention) + TokensEstimator.estimate(spec.notice)

      Budget.remaining(messages, limit) < pair_size
    else
      false
    end
  end

  defp projected_tokens_for_response(response, state, messages) do
    ctx = %{state.live.machine.work.ctx | messages: messages}

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
    base = ConversationSize.size(messages)
    text_size = TokensEstimator.estimate(response.text || "")
    base + text_size + 10
  end

  defp put_pending_notice(state, value) do
    machine = state.live.machine

    %{
      state
      | live: %{
          state.live
          | machine: %{machine | work: %{machine.work | pending_notice: value}}
        }
    }
  end

  defp put_context_projection(state, tokens) do
    %{state | live: %{state.live | context_projection: tokens}}
  end

  defp put_crossed_thresholds(state, set) do
    %{state | live: %{state.live | crossed_thresholds: set}}
  end
end
