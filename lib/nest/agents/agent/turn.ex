defmodule Nest.Agents.Agent.Turn do
  @moduledoc """
  The Agent's in-process turn driver.

  The Agent itself owns and drives a chat turn: this module ports the
  iteration loop that used to live in the `ChatTurn` GenServer into
  functions that operate on the Agent state. HTTP/tool calls still run
  as `Task` workers, but they report back to the Agent tagged with the
  turn's `worker_ref`; a result is applied only when its ref and phase
  match the live turn, so a stale or duplicate result (one that arrives
  after a stop or a finalize) is dropped.

  ## Entry shapes

  The `entry` carried on `live.turn` selects the first iteration's
  behavior:

    * `{:user_message, User.t()}` — the message is already appended;
      first iteration calls the LLM.
    * `{:tool_call, Assistant.t(), iter, max}` — the carried
      assistant+ToolUse is at the tail; first iteration executes it.
    * `{:compact_tool, [Assistant.t(), Tool.t()], iter, max}` — the
      carried pair is at the tail; first iteration falls through to the
      LLM.
    * `{:compaction, staged, entry | nil}` — the compactor's own turn.
      First iteration calls the LLM with `tools: nil, tool_choice: :none`
      and finishes with `{:compaction_done, ...}`.
    * `{:assistant_response, Assistant.t(), iter, max}` — a deferred
      terminal reply; committed by the compaction result handler.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.ChatState.Live.Turn
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler
  alias Nest.Agents.Agent.Handlers.TurnHandler
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.Iteration
  alias Nest.Agents.Agent.Turn.Lifecycle
  alias Nest.Agents.Agent.Turn.Messages
  alias Nest.Agents.Agent.Turn.ResponseHandler
  alias Nest.Messages.Part

  # Client API used by the pipeline / compaction trigger / result handler.

  @doc """
  Start a turn on `state`. Sets `live.turn` from the entry and queues the
  first `:iterate`. `caps` is the resolved capability map for the mode.
  """
  @spec start(Agent.t(), list(), Turn.entry(), map()) :: Agent.t()
  def start(state, messages, entry, caps) do
    ctx = build_ctx(state, messages, caps)

    turn = %Turn{
      ctx: ctx,
      iteration: initial_iteration(entry),
      max_iterations: initial_max_iterations(entry),
      entry: entry
    }

    state = %{state | live: %{state.live | turn: turn}}
    send(self(), :iterate)
    state
  end

  # Server callbacks

  @doc """
  Dispatch a turn message. Returns the GenServer reply tuple.
  """
  @spec handle(term(), Agent.t()) :: GenServer.reply()
  def handle(:iterate, state), do: iterate(state)

  def handle({:http_response, ref, response}, state) when is_map(response) do
    if valid_worker?(state, ref, :http) do
      handle_response(response, state)
    else
      {:noreply, state}
    end
  end

  def handle({:http_error, ref, _error}, state) do
    if valid_worker?(state, ref, :http) do
      Lifecycle.finalize_turn(state)
    else
      {:noreply, state}
    end
  end

  def handle({:worker_crashed, ref, exception, stacktrace}, state) do
    if valid_worker?(state, ref, nil) do
      {:noreply, TurnHandler.chat_crashed_state(exception, stacktrace, state)}
    else
      {:noreply, state}
    end
  end

  def handle({:tool_results, ref, results}, state) do
    if valid_worker?(state, ref, :tools) do
      handle_tool_results(results, state)
    else
      {:noreply, state}
    end
  end

  def handle({:DOWN, _mref, :process, pid, reason}, state) do
    if pid == state.live.turn.active_worker do
      Lifecycle.worker_exited(pid, reason, state)
    else
      {:noreply, state}
    end
  end

  # The worker ref must match the live turn (drops stale results) and,
  # when given, the phase must match the in-flight worker kind.
  defp valid_worker?(state, ref, kind) do
    turn = state.live.turn

    is_reference(turn.worker_ref) and turn.worker_ref == ref and
      (kind == nil or turn.active_worker_kind == kind)
  end

  # Iteration

  defp iterate(%{live: %{turn: %{ctx: nil}}} = state), do: {:noreply, state}

  defp iterate(state) do
    safe_iterate(state)
  catch
    :exit, _ -> {:noreply, state}
  end

  defp safe_iterate(state) do
    state = maybe_inject_budget_reminder(state)
    state = update_turn(state, &%{&1 | iteration: &1.iteration + 1})

    Iteration.notify_max_iterations(state)

    messages = state.chat_state.messages
    next_index = state.chat_state.next_message_index

    state =
      update_turn(state, fn turn ->
        %{
          turn
          | active_message_index: active_index(turn, next_index),
            ctx: %{turn.ctx | messages: messages}
        }
      end)

    iteration_branch(state, messages, state.live.cancelled)
  end

  defp active_index(%Turn{entry: {:compaction, staged, _}}, next_index),
    do: next_index + length(staged)

  defp active_index(_turn, next_index), do: next_index

  defp iteration_branch(state, messages, cancelled) do
    cond do
      cancelled ->
        {:noreply, state |> Lifecycle.clear_turn() |> TurnHandler.chat_stopped_state()}

      pending_tool_calls?(messages) ->
        execute_pending_tool_calls(state, messages)

      compactor_entry?(state) ->
        Iteration.dispatch_compaction(state, messages)

      true ->
        Iteration.dispatch_batch(state, messages)
    end
  end

  defp compactor_entry?(state), do: match?({:compaction, _, _}, state.live.turn.entry)

  defp pending_tool_calls?(messages) do
    case List.last(messages) do
      {:assistant, %{parts: parts}} when is_list(parts) ->
        Enum.any?(parts, &match?(%Part.ToolUse{}, &1))

      _ ->
        false
    end
  end

  defp execute_pending_tool_calls(state, messages) do
    [{:assistant, %{parts: parts}} | _] = Enum.reverse(messages)
    tool_calls = ResponseHandler.extract_tool_calls_from_parts(parts)

    case BatchSizer.preflight(ToolLoop.strip_context_compact(tool_calls), state.live.turn.ctx) do
      :fits ->
        Iteration.spawn_tool_worker(state, tool_calls)

      {:refuse, _reason} ->
        continuation =
          {:tool_call, List.last(messages), state.live.turn.iteration,
           state.live.turn.max_iterations}

        send(self(), {:needs_compaction, self(), continuation})
        {:noreply, state}
    end
  end

  defp initial_iteration({_tag, _msg, n, _max}) when is_integer(n), do: n
  defp initial_iteration(_), do: 0

  defp initial_max_iterations({_tag, _msg, _n, m}) when is_integer(m), do: m
  defp initial_max_iterations(_), do: Config.configured_max_tool_iterations()

  defp maybe_inject_budget_reminder(state) do
    turn = state.live.turn
    remaining = turn.max_iterations - turn.iteration

    case BudgetReminder.notice_text(remaining) do
      nil ->
        state

      notice ->
        update_turn(state, &%{&1 | pending_notice: &1.pending_notice || notice})
    end
  end

  # Response

  defp handle_response(response, state) do
    if state.live.cancelled do
      {:noreply, state |> Lifecycle.clear_turn() |> TurnHandler.chat_stopped_state()}
    else
      ResponseHandler.handle(response, state)
    end
  end

  defp handle_tool_results(results, state) do
    state =
      update_turn(state, &%{&1 | active_worker: nil, active_worker_kind: nil, worker_ref: nil})

    if state.live.cancelled do
      {:noreply, state |> Lifecycle.clear_turn() |> TurnHandler.chat_stopped_state()}
    else
      {:tool, tool} = Messages.tool(results)
      {:noreply, state} = LLMStreamHandler.tool_results_received(tool, state)
      state = update_turn(state, &%{&1 | pending_notice: nil})
      send(self(), :iterate)
      {:noreply, state}
    end
  end

  # Context

  defp build_ctx(state, messages, caps) do
    %{
      agent_pid: self(),
      agent_name: state.name,
      space_id: state.space_id,
      client_config: state.client_config,
      tools: state.tools,
      tool_choice: :auto,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      messages: messages,
      tmp_path: state.tmp_path,
      workspace_path: state.workspace_path,
      crossed_thresholds: state.live.crossed_thresholds
    }
  end

  defp update_turn(state, fun) do
    %{state | live: %{state.live | turn: fun.(state.live.turn)}}
  end
end
