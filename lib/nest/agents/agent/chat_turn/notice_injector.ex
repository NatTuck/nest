defmodule Nest.Agents.Agent.ChatTurn.NoticeInjector do
  @moduledoc """
  Case 2 notice injection at the LLM-response-construction site.

  Each trigger source (budget reminder, context-usage threshold)
  produces a `%{kind, attention, notice}` spec, and this module
  collects them and injects each as a synthetic
  `[assistant(attention), user(notice)]` pair before the LLM's
  response.

  When multiple specs fire on the same iteration, all are injected
  in the order returned by `collect_case2_specs/2` (budget first,
  then context). The `active_message_index` correction in the
  caller is `+ 2 * length(specs)`.

  This module is a pure helper — it does not own any state. All
  state lives on the Agent (via `state.ctx.agent_pid`) and the
  ChatTurn (via `state.pending_notice`, `state.ctx.crossed_thresholds`).
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.ChatTurn.BudgetReminder
  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Tokens.Estimator, as: TokensEstimator
  alias Nest.Tokens.Reserve

  @doc """
  Collect notice specs from all trigger sources.

  Trigger sources:
  1. Budget reminder: `state.pending_notice` was set by
     `chat_turn.maybe_inject_budget_reminder/1` because
     remaining iterations ≤ 2.
  2. Context-usage threshold: the projected context usage
     (including this response, plus predicted tool result
     sizes for tool_use responses) crosses a new threshold.

  Priority: budget wins when both fire on the same iteration —
  it's the more urgent signal. Both pairs are injected (4 extra
  messages) — we don't lie to the user, we send what we send.

  Returns a list of specs (possibly empty, possibly of length 1
  or 2). The order of the list is the injection order.
  """
  @spec collect_case2_specs(RunResponse.t(), State.t()) :: [ContextReminder.spec()]
  def collect_case2_specs(response, state) do
    budget =
      if state.pending_notice, do: BudgetReminder.spec_from_pending(state.pending_notice)

    context = compute_context_spec(response, state)

    [budget, context] |> Enum.reject(&is_nil/1)
  end

  @doc """
  Collect specs, inject each, update bookkeeping, and return
  the number of pairs injected. The caller uses this to
  advance `active_message_index` by `2 * count`.
  """
  @spec inject_all(RunResponse.t(), State.t()) :: {non_neg_integer(), State.t()}
  def inject_all(response, state) do
    specs = collect_case2_specs(response, state)
    state = inject_specs(specs, state)

    state =
      if Enum.any?(specs, &(&1.kind == :budget)) do
        %{state | pending_notice: nil}
      else
        state
      end

    _ = update_crossed_thresholds_for_context(response, state)

    {length(specs), state}
  end

  defp compute_context_spec(response, state) do
    limit = state.ctx.context_limit

    if not is_integer(limit) or limit <= 0 do
      nil
    else
      crossed = fetch_crossed_thresholds(state)
      projected = projected_tokens_for_response(response, state)
      ContextReminder.spec(projected, limit, crossed)
    end
  end

  # Update the Agent's `crossed_thresholds` set after a context
  # spec has been injected. Called from `inject_all/2` so the
  # threshold doesn't re-fire on subsequent iterations.
  defp update_crossed_thresholds_for_context(response, state) do
    limit = state.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      crossed = fetch_crossed_thresholds(state)
      projected = projected_tokens_for_response(response, state)

      case ContextReminder.highest_unannounced(projected, limit, crossed) do
        nil ->
          :ok

        atom ->
          new_set = MapSet.put(crossed, atom)
          send(state.ctx.agent_pid, {:set_crossed_thresholds, new_set})
          :ok
      end
    else
      :ok
    end
  end

  defp inject_specs([], state), do: state

  defp inject_specs([spec | rest], state) do
    state = inject_one_spec(spec, state)
    inject_specs(rest, state)
  end

  defp inject_one_spec(%{attention: attention, notice: notice}, state) do
    # The ChatTurn process can't call `Agent.__append_message__/2`
    # directly (that function mutates Agent state from within the
    # Agent process). Use the canonical `{:append_message, _}`
    # GenServer.call so the Agent appends each message atomically
    # and broadcasts the `chat:message` events to the UI.
    #
    # If the Agent has shut down between the LLM call and this
    # point (chat crash, user stop, etc.), the calls will exit
    # and we silently skip the injection — the Agent is gone, so
    # there's no one to receive the messages anyway. This
    # prevents the ChatTurn from crashing on the crash path.
    case append_messages(state, attention, notice) do
      :agent_dead -> state
      :ok -> state
    end
  end

  defp append_messages(state, attention, notice) do
    _stamped_attention =
      GenServer.call(
        state.ctx.agent_pid,
        {:append_message, build_attention_assistant(attention)},
        5_000
      )

    _stamped_notice =
      GenServer.call(
        state.ctx.agent_pid,
        {:append_message, ContextReminder.build_user_notice(notice, state.ctx.client_config)},
        5_000
      )

    :ok
  rescue
    _ -> :agent_dead
  catch
    :exit, _ -> :agent_dead
  end

  # Best-effort: the Agent may have shut down between the LLM
  # call and the response handler running (chat crash, user
  # stop, etc.). If the GenServer.call fails or exits, fall
  # back to the cached `crossed_thresholds` on `state.ctx` (or
  # an empty set). The threshold update is bookkeeping — losing
  # it doesn't break the wire format, just means the next
  # iteration (if any) might re-fire the threshold once.
  defp fetch_crossed_thresholds(state) do
    GenServer.call(state.ctx.agent_pid, :get_crossed_thresholds, 1_000)
  rescue
    _ -> state.ctx.crossed_thresholds || MapSet.new()
  catch
    :exit, _ -> state.ctx.crossed_thresholds || MapSet.new()
  end

  defp projected_tokens_for_response(response, state) do
    {messages, _cancelled} =
      try do
        GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled, 1_000)
      catch
        :exit, _ -> {state.ctx.messages || [], false}
      end

    ctx = %{state.ctx | messages: messages}

    case response.tool_calls do
      nil ->
        projected_text(messages, response, state.ctx.context_limit)

      [] ->
        projected_text(messages, response, state.ctx.context_limit)

      tool_calls ->
        case BatchSizer.preflight(tool_calls, ctx) do
          :fits ->
            TokensEstimator.estimate_messages(messages) +
              tool_request_size(tool_calls) +
              Reserve.response_budget(state.ctx.context_limit)

          {:refuse, _reason} ->
            state.ctx.context_limit
        end
    end
  end

  defp projected_text(messages, response, _limit) do
    base = TokensEstimator.estimate_messages(messages)
    text_size = TokensEstimator.estimate(response.text || "")
    base + text_size + 10
  end

  defp tool_request_size(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
      TokensEstimator.estimate(Jason.encode!(tc.arguments || %{})) + 20
    end)
    |> Enum.sum()
  end

  defp build_attention_assistant(text) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: text}],
       api_logs: []
     }}
  end
end
