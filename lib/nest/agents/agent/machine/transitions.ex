defmodule Nest.Agents.Agent.Machine.Transitions do
  @moduledoc """
  The pure transition table for `Nest.Agents.Agent.Machine`.

  `do_step/2` is dispatched by `Machine.step/2`. Every clause here is a
  pure function of `(machine, event)`: it returns the actions the
  executor must run and the next machine. No clause performs an effect,
  and only this namespace writes `phase:` on a machine.

  The chat-response branch lives in `Machine.Response` (also pure); this
  module owns the phase-level transitions, worker/timer bookkeeping,
  child-event delegation, and the compaction staging/resume decisions.

  `:iterate` actions are emitted (never run inline) so the executor
  defers them through the mailbox, preserving the old driver's async
  boundary between appending and spawning a worker.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.Turn.Messages, as: TurnMessages
  alias Nest.Agents.Agent.Turn.Terminal
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.Messages.MessageList

  # Compile-time copies of the blocked phases so guards stay valid.
  @blocked [
    :needs_repair,
    :model_missing,
    :context_overflow,
    :compaction_failed,
    :compaction_loop_detected
  ]

  defdelegate enter(m, kind, phase), to: Phase
  defdelegate enter(m, kind, phase, worker_kind), to: Phase
  defdelegate enter_blocked(m, phase), to: Phase
  defdelegate clear_worker(m), to: Phase
  defdelegate unwrap_user(entry), to: Phase
  defdelegate init_turn(machine, entry), to: Phase
  defdelegate put_ctx(m, changes), to: Phase

  # --- child events (any phase) ---

  def do_step(%Machine{} = m, {:child_spawned, name, worker_ref, archive}) do
    case Children.spawn(m.children, name, worker_ref, archive) do
      {:ok, _actions, children} -> {:ok, [], %{m | children: children}}
      {:ignore, reason, children} -> {:ignore, reason, %{m | children: children}}
    end
  end

  def do_step(%Machine{} = m, {:child_completed, name, response, usage}) do
    child_event(m, {:completed, name, response, usage})
  end

  def do_step(%Machine{} = m, {:child_failed, name, reason}) do
    child_event(m, {:failed, name, reason})
  end

  def do_step(%Machine{} = m, {:child_terminated, name, reason}) do
    child_event(m, {:terminated, name, reason})
  end

  def do_step(%Machine{} = m, {:abandon_child, name}) do
    child_event(m, {:abandoned, name})
  end

  # --- blocked exits ---

  def do_step(%{phase: :compaction_failed} = m, :retry_compaction) do
    case m.mid_turn_entry do
      # No mid-turn continuation: a post-turn retry resumes the held user
      # message after the compaction (the pending field is carried on the
      # machine, not as the compaction continuation).
      nil -> Compaction.stage(%{m | mid_turn_entry: nil}, nil, nil)
      entry -> Compaction.stage(%{m | mid_turn_entry: nil}, entry.entry, nil)
    end
  end

  def do_step(%{phase: :compaction_loop_detected} = m, :loop_ack) do
    machine =
      enter(%{m | loop_count: 0, pending_user_message: nil, mid_turn_entry: nil}, :chat, :idle)

    {:ok, [{:drain_inbox}], machine}
  end

  # --- blocked-enter / unblocked (before the generic blocked catch-all) ---

  def do_step(%Machine{} = m, {:blocked, phase, _reason}) when phase in @blocked do
    {:ok, [], enter_blocked(m, phase)}
  end

  def do_step(%{phase: p} = m, {:unblocked}) when p in @blocked do
    {:ok, [{:drain_inbox}], enter(m, :chat, :idle)}
  end

  # Blocked phases reject ordinary work until an exit event unsticks them.
  def do_step(%{phase: p} = m, _event) when p in @blocked, do: {:ignore, :blocked, m}

  # --- stop ---

  def do_step(%{phase: :stopping} = m, {:stop, _channel}), do: {:ignore, :already_stopping, m}
  def do_step(%{phase: :idle} = m, {:stop, _channel}), do: {:ignore, :already_idle, m}

  def do_step(%Machine{} = m, {:stop, channel}) do
    actions = [{:ack, channel, :stopped}, {:set_cancelled, true}, {:stop_all_children}]
    actions = if m.stop_timer, do: actions ++ [{:cancel_timer, m.stop_timer}], else: actions

    actions =
      if m.work.active_worker, do: actions ++ [{:kill, m.work.active_worker}], else: actions

    actions = actions ++ [{:arm_timer, Config.configured_stop_fallback_ms(), :stop_timer}]

    machine =
      Machine.validate!(%{
        m
        | phase: :stopping,
          stop_timer: nil,
          work: %{m.work | worker_kind: nil, active_worker_kind: nil}
      })

    {:ok, actions, machine}
  end

  def do_step(%{phase: :stopping} = m, :stop_timer) do
    machine = enter(%{m | stop_timer: nil}, m.kind, :idle)

    {:ok, [{:stop_all_children}, {:finalize, Terminal.stopped_metadata()}, {:drain_inbox}],
     machine}
  end

  def do_step(%{phase: :stopping} = m, {:http_ok, _ref, _response}),
    do: {:ignore, :late_result_after_stop, m}

  def do_step(%{phase: :stopping} = m, {:tool_results, _ref, _results}),
    do: {:ignore, :late_result_after_stop, m}

  # --- timer bookkeeping ---

  def do_step(%Machine{} = m, {:timer_armed, :stop_timer, ref}) do
    {:ok, [], %{m | stop_timer: ref}}
  end

  def do_step(%Machine{} = m, {:timer_armed, _token, _ref}), do: {:ignore, :unknown_timer, m}

  # --- worker bookkeeping ---

  def do_step(%{phase: :stopping} = m, {:worker_started, _ref, pid, _kind}) do
    {:ok, [{:kill, pid}], m}
  end

  def do_step(%{phase: p} = m, {:worker_started, ref, pid, kind})
      when p in [:generating, :executing_tools] do
    if m.work.worker_kind == kind do
      {:ok, [],
       %{m | work: %{m.work | worker_ref: ref, active_worker: pid, active_worker_kind: kind}}}
    else
      {:ok, [{:kill, pid}], m}
    end
  end

  def do_step(%Machine{} = m, {:worker_started, _ref, pid, _kind}) do
    {:ok, [{:kill, pid}], m}
  end

  def do_step(%{phase: :stopping} = m, {:worker_down, _pid, _reason}),
    do: {:ignore, :late_worker_down, m}

  def do_step(%Machine{} = m, {:worker_down, pid, reason}) do
    if is_pid(pid) and pid == m.work.active_worker do
      worker_down(m, reason)
    else
      {:ignore, :unknown_worker_down, m}
    end
  end

  # --- idle ---

  def do_step(%{phase: :idle} = m, {:chat_request, entry}), do: start_chat(m, entry, nil)

  def do_step(%{phase: :idle} = m, {:inbox_drain, entries, content}) do
    user = Dispatch.build_user_message(content, m.work.ctx.mode)
    start_chat(m, {:user_message, user}, entries)
  end

  def do_step(%{phase: :idle} = m, {:compaction_request, entry}),
    do: Compaction.stage(m, entry, m.pending_user_message)

  def do_step(%{phase: :idle} = m, {:http_ok, _ref, _response}), do: {:ignore, :stale_result, m}

  def do_step(%{phase: :idle} = m, {:tool_results, _ref, _results}),
    do: {:ignore, :stale_result, m}

  # A resumed held user message waits in `:idle` (so its terminal append can
  # bridge the wire); the `:iterate` promotes to `:generating` and dispatches.
  def do_step(%{phase: :idle, entry: {:user_message, _}} = m, :iterate) do
    iterate(enter(m, :chat, :generating, :http))
  end

  def do_step(%{phase: :idle} = m, :iterate), do: {:ignore, :not_applicable, m}
  def do_step(%{phase: :idle} = m, :stop_timer), do: {:ignore, :not_applicable, m}

  def do_step(%{phase: :idle} = m, {:append_result, :invalid, reason}) do
    fail_turn(m, %ArgumentError{message: reason}, [])
  end

  def do_step(%{phase: :idle} = m, {:append_result, :stale, _}), do: {:ignore, :stale_append, m}

  # --- workspace notice ---

  def do_step(%{phase: :idle, work: %{pending_notice: path}} = m, :workspace_notice)
      when is_binary(path) do
    pair = WorkspaceHandler.notice_pair(path)
    projected = messages(m) ++ pair
    limit = m.work.ctx.context_limit

    case Dispatch.preflight_decision(projected, limit) do
      :fits ->
        machine = %{m | work: %{m.work | pending_notice: nil}}
        {:ok, [{:append_many, pair}, {:drain_inbox}], enter(machine, :chat, :idle)}

      :needs_compaction ->
        Compaction.stage(m, nil, nil)

      :cannot_compact ->
        machine = enter_blocked(%{m | work: %{m.work | pending_notice: nil}}, :context_overflow)

        {:ok, [{:broadcast, {:overflow, :reserve_exhausted, "start a conversation"}, nil}],
         machine}
    end
  end

  def do_step(%{phase: :idle} = m, :workspace_notice), do: {:ignore, :no_pending_notice, m}

  # --- generating (chat) ---

  def do_step(%{phase: :generating, kind: :chat} = m, {:http_ok, ref, response})
      when is_map(response) do
    if valid_ref?(m, ref), do: Response.dispatch(m, response), else: {:ignore, :stale_result, m}
  end

  # A dedicated stream-error path: persist the partial + error text as the
  # assistant message, then idle. Distinct from a turn crash (repair).
  def do_step(%{phase: :generating, kind: :chat} = m, {:llm_error, ref, msg}) do
    if valid_ref?(m, ref) do
      machine = enter(clear_worker(m), :chat, :idle)
      {:ok, [{:llm_error, msg}, {:drain_inbox}], machine}
    else
      {:ignore, :stale_result, m}
    end
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:http_error, ref, reason}) do
    if valid_ref?(m, ref), do: fail_turn(m, reason, []), else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:worker_crashed, ref, exception, st}) do
    if valid_ref?(m, ref), do: fail_turn(m, exception, st), else: {:ignore, :stale_result, m}
  end

  def do_step(
        %{phase: :generating, kind: :chat, work: %{preflight: nil}} = m,
        {:preflight_result, _}
      ),
      do: {:ignore, :no_preflight, m}

  def do_step(%{phase: :generating, kind: :chat} = m, {:preflight_result, :fits}) do
    %{calls: calls} = m.work.preflight
    machine = enter(m, :chat, :executing_tools, :tools)
    {:ok, [{:spawn_tools, machine.work.ctx, calls}], machine}
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:preflight_result, {:refuse, _reason}}) do
    Compaction.stage(m, m.work.preflight.continuation, nil)
  end

  def do_step(%{phase: :generating, kind: :chat} = m, :iterate), do: iterate(m)

  def do_step(%{phase: :generating, kind: :chat} = m, {:compaction_request, entry}) do
    Compaction.stage(m, entry, nil)
  end

  def do_step(%{phase: :executing_tools} = m, {:compaction_request, entry}) do
    Compaction.stage(m, entry, nil)
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:append_result, :invalid, reason}) do
    fail_turn(m, %ArgumentError{message: reason}, [])
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:append_result, :stale, _}),
    do: {:ignore, :stale_append, m}

  def do_step(%{phase: :generating, kind: :chat} = m, {:tool_results, _ref, _results}),
    do: {:ignore, :stale_result, m}

  # --- executing tools ---

  def do_step(%{phase: :executing_tools} = m, {:tool_results, ref, results}) do
    if valid_ref?(m, ref), do: tool_results(m, results), else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :executing_tools} = m, {:append_result, :invalid, reason}) do
    fail_turn(m, %ArgumentError{message: reason}, [])
  end

  def do_step(%{phase: :executing_tools} = m, {:append_result, :stale, _}),
    do: {:ignore, :stale_append, m}

  def do_step(%{phase: :executing_tools} = m, {:http_ok, _ref, _response}),
    do: {:ignore, :stale_result, m}

  # --- compaction (generating) ---

  def do_step(%{phase: :generating, kind: :compaction} = m, {:http_ok, ref, response}) do
    if valid_ref?(m, ref),
      do: Compaction.commit_compaction(m, response),
      else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :generating, kind: :compaction} = m, {:compaction_ok, data}) do
    {:ok, [{:commit_compaction, data}], enter(m, :compaction, :committing)}
  end

  def do_step(%{phase: :generating, kind: :compaction} = m, {:compaction_error, reason, carried}) do
    Compaction.compaction_failed(m, reason, carried)
  end

  def do_step(%{phase: :generating, kind: :compaction} = m, {:http_error, ref, reason}) do
    if valid_ref?(m, ref),
      do: Compaction.compaction_failed(m, reason, Compaction.carried(m)),
      else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :generating, kind: :compaction} = m, {:worker_crashed, ref, ex, _st}) do
    if valid_ref?(m, ref),
      do: Compaction.compaction_failed(m, ex, Compaction.carried(m)),
      else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :generating, kind: :compaction} = m, {:compaction_request, entry}) do
    Compaction.stage(m, entry, nil)
  end

  # The staged compaction request was assembled; spawn the compactor.
  def do_step(%{phase: :generating, kind: :compaction} = m, :iterate) do
    provisional = m.work.active_message_index
    ctx = Dispatch.spawn_ctx(m, Dispatch.request_messages(m))
    {:ok, [{:set_streaming, provisional}, {:stage_compaction, ctx}], m}
  end

  # --- committing ---

  def do_step(%{phase: :committing, entry: {:compaction, _, _}} = m, {:commit_done}),
    do: Compaction.resume(m)

  def do_step(%{phase: :committing} = m, {:commit_done}), do: {:ignore, :no_compaction, m}

  def do_step(%{phase: :committing} = m, {:commit_error, reason}),
    do: Compaction.compaction_failed(m, reason, Compaction.carried(m))

  def do_step(%{phase: :committing} = m, {:append_result, :invalid, reason}),
    do: Compaction.compaction_failed(m, reason, Compaction.carried(m))

  def do_step(%{phase: :committing} = m, {:append_result, :stale, _}),
    do: Compaction.compaction_failed(m, :stale_compaction_append, Compaction.carried(m))

  # --- defaults ---

  def do_step(%Machine{} = m, _event), do: {:ignore, :not_applicable, m}

  # --- chat start / preflight ---

  defp start_chat(m, entry, _inbox_entries) do
    user = unwrap_user(entry)
    projected = messages(m) ++ [user]
    limit = m.work.ctx.context_limit

    case Dispatch.preflight_decision(projected, limit) do
      :fits ->
        {notice_actions, m} = user_notice_actions(m, projected)
        machine = init_turn(enter(m, :chat, :generating, :http), entry)
        {:ok, notice_actions ++ [{:append, user}, :iterate], machine}

      :needs_compaction ->
        Compaction.stage(%{m | pending_user_message: entry}, nil, nil)

      :cannot_compact ->
        machine = enter_blocked(m, :context_overflow)

        {:ok, [{:broadcast, {:overflow, :reserve_exhausted, "start a conversation"}, nil}],
         machine}
    end
  end

  defp user_notice_actions(m, projected) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      used = ContextReminder.estimate_messages(projected)
      crossed = m.work.ctx.crossed_thresholds

      case ContextReminder.highest_unannounced(used, limit, crossed) do
        nil -> {[], m}
        atom -> build_user_notice(m, atom, used, crossed)
      end
    else
      {[], m}
    end
  end

  defp build_user_notice(m, atom, used, crossed) do
    compact? = ContextReminder.compact_available?(m.work.ctx.tools)
    notice = ContextReminder.notice_text(atom, compact?)
    ack = ContextReminder.ack_text_for(atom, compact?)

    spec = %{kind: :context, attention: "Context?", notice: notice, ack: ack, threshold: atom}

    case NoticePairInjector.build_pair(messages(m), spec, :user_agent) do
      {:ok, pair} ->
        set = MapSet.put(crossed, atom)

        actions = [
          {:append_many, pair},
          {:set_crossed_thresholds, set},
          {:set_context_projection, used}
        ]

        {actions, put_ctx(m, crossed_thresholds: set, context_projection: used)}

      :deferred ->
        {[], m}
    end
  end

  # --- iterate / dispatch ---

  defp iterate(m) do
    case MessageList.unpaired_tail_tool_uses(messages(m)) do
      [] -> dispatch_http(m)
      uses -> preflight_pending_tools(m, uses)
    end
  end

  defp dispatch_http(m) do
    pre_iteration = m.work.iteration
    notice = BudgetReminder.notice_text(m.work.max_iterations - pre_iteration)
    pending_notice = m.work.pending_notice || notice
    iteration = pre_iteration + 1

    ctx = m.work.ctx
    idx = ctx.next_message_index

    base = %{m | work: %{m.work | iteration: iteration, pending_notice: pending_notice}}
    spawn_ctx = Dispatch.spawn_ctx(base, ctx.messages)

    machine = %{
      enter(base, :chat, :generating, :http)
      | work: %{base.work | iteration: iteration, active_message_index: idx}
    }

    actions =
      if iteration > m.work.max_iterations do
        [
          {:broadcast,
           {:notification, %{type: "max_iterations", message: "Max tool iterations reached"}},
           nil},
          {:set_streaming, idx},
          {:spawn_http, spawn_ctx}
        ]
      else
        [{:set_streaming, idx}, {:spawn_http, spawn_ctx}]
      end

    {:ok, actions, machine}
  end

  defp preflight_pending_tools(m, _uses) do
    {:assistant, assistant} = List.last(messages(m))
    calls = Response.tool_calls_from_parts(assistant.parts)
    continuation = {:tool_call, {:assistant, assistant}, m.work.iteration, m.work.max_iterations}
    machine = %{m | work: %{m.work | preflight: %{calls: calls, continuation: continuation}}}
    {:ok, [{:preflight, m.work.ctx, calls, continuation}], machine}
  end

  # --- tool results ---

  defp tool_results(m, results) do
    {:tool, _tool} = tool_msg = TurnMessages.tool(results)
    machine = enter(m, :chat, :generating, :http)
    machine = %{machine | work: %{machine.work | pending_notice: nil}}

    {:ok, [{:append, tool_msg}, {:record_file_access}, :iterate], machine}
  end

  # --- worker death / terminal ---

  defp worker_down(m, reason) do
    cond do
      m.work.active_worker_kind == :tools ->
        recover_interrupted_tool(m)

      reason == :normal ->
        {:ok, [], clear_worker(m)}

      reason in [:shutdown, :killed] or match?({:shutdown, _}, reason) ->
        machine = enter(clear_worker(m), :chat, :idle)
        {:ok, [{:finalize, Terminal.stopped_metadata()}, {:drain_inbox}], machine}

      true ->
        fail_turn(m, reason, [])
    end
  end

  defp recover_interrupted_tool(m) do
    case Repair.decide(:worker_death, messages(m), nil) do
      :none ->
        machine = enter(clear_worker(m), :chat, :idle)
        {:ok, [{:finalize, Terminal.stopped_metadata()}, {:drain_inbox}], machine}

      {:repair, [tool_msg]} ->
        machine = enter(clear_worker(m), :chat, :generating, :http)

        {:ok,
         [
           {:log, :warning, "tool worker died; answering tool_use with an error result"},
           {:append, tool_msg},
           :iterate
         ], machine}
    end
  end

  defp fail_turn(m, reason, stacktrace) do
    machine = enter(clear_worker(m), :chat, :idle)
    {:ok, [{:fail_turn, reason, stacktrace}, {:drain_inbox}], machine}
  end

  defp valid_ref?(m, ref) do
    not Machine.stopping?(m) and is_reference(m.work.worker_ref) and m.work.worker_ref == ref
  end

  defp messages(m), do: m.work.ctx.messages

  defp child_event(m, event) do
    case Children.step(m.children, event) do
      {:ok, actions, children} ->
        actions = resolve_worker_pids(actions, m.children) ++ [{:broadcast, :status, nil}]
        {:ok, actions, %{m | children: children}}

      {:ignore, reason, children} ->
        {:ignore, reason, %{m | children: children}}
    end
  end

  # Children.terminal clears the worker_ref, so capture the running
  # entry's pid before stepping and pass it with the notify action.
  defp resolve_worker_pids(actions, %Children{children: running}) do
    Enum.map(actions, fn
      {:notify_worker, name, result} ->
        pid =
          case running[name] do
            %{worker_ref: pid} when is_pid(pid) -> pid
            _ -> nil
          end

        {:notify_worker, name, pid, result}

      other ->
        other
    end)
  end
end
