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

  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Backgrounding
  alias Nest.Agents.Agent.Machine.Boundary
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Machine.Delivery
  alias Nest.Agents.Agent.Machine.Failure
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Machine.Stopping
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.Turn.Messages, as: TurnMessages
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.LLM.Preflight
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
  defdelegate clear_worker(m), to: Phase
  defdelegate unwrap_user(entry), to: Phase
  defdelegate held_user(m), to: Phase
  defdelegate init_turn(machine, entry), to: Phase
  defdelegate put_ctx(m, changes), to: Phase

  # --- child events (any phase) ---

  def do_step(%Machine{} = m, {:child_spawned, name, archive, target}) do
    case Children.register(m.children, name, archive, target) do
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

  # --- stop guards ---

  # A stopped turn drops late results: the stop path kills the batch's worker
  # and records the cancellation itself (`Machine.Stopping`, issue #36 step 4),
  # so delivering a backgrounded result here as well would report the same call
  # twice. These are the first clauses in the file, so nothing below can preempt
  # a stop.
  def do_step(%{phase: :stopping} = m, {:http_ok, _ref, _response}),
    do: {:ignore, :late_result_after_stop, m}

  def do_step(%{phase: :stopping} = m, {:tool_results, _ref, _results}),
    do: {:ignore, :late_result_after_stop, m}

  def do_step(%{phase: :stopping} = m, {:worker_down, _pid, _reason}),
    do: {:ignore, :late_worker_down, m}

  # --- backgrounded batches (issue #36) ---

  # A late result for a batch that was moved to the background when a message
  # arrived. It is keyed on `work.backgrounded`, not the phase: it must land
  # whatever the phase or kind (a compaction keeps `work`), and even while a
  # *new* batch is in flight. Below the stop guards and above every stale/late,
  # blocked and phase clause; the entry is cleared here, so the ref answers once.
  # `delivery_actions/2` adds the drain an already-idle machine needs.
  def do_step(%{work: %{backgrounded: backgrounded}} = m, {:tool_results, ref, results})
      when is_map_key(backgrounded, ref),
      do:
        {:ok,
         Backgrounding.delivery_actions(m, [
           {:deliver_backgrounded, ref, {:results, results}, Backgrounding.fulfilled_ids(results)}
         ]), Backgrounding.clear(m, [ref])}

  # A backgrounded worker that dies is not the `active_worker` (it was moved out
  # when the batch was backgrounded), so it must be resolved here before either
  # arm below can swallow it: the `:compaction` arm would answer
  # `:unknown_worker_down`, leaking the entry with no notice. Every ref the dead
  # pid owns is resolved (two entries can share a pid).
  def do_step(%Machine{} = m, {:worker_down, pid, reason}) do
    case Backgrounding.refs_for(m, pid) do
      [] ->
        unowned_worker_down(m, pid, reason)

      refs ->
        # A death delivers no result, so the calls it closes come from the
        # entry (`Backgrounding.ids_for/2`): the notice carries them, and the
        # message it becomes is marked fulfilled — without that a later load
        # would append a second record for a promise the death notice already
        # closed honestly.
        actions =
          Enum.map(refs, fn ref ->
            {:deliver_backgrounded, ref, {:worker_down, reason}, Backgrounding.ids_for(m, ref)}
          end)

        {:ok, Backgrounding.delivery_actions(m, actions), Backgrounding.clear(m, refs)}
    end
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
    # The loop breaker must not swallow a message the machine was holding, and
    # must not re-enter the compaction decision it just gave up on. Both
    # dispositions append the message to the transcript *before* anything else
    # runs; a refused append surfaces as `{:append_result, :invalid, _}` — a
    # visible turn failure instead of a silent drop.
    #
    #  * A parked chat request (`pending_user_message`) is appended directly:
    #    the machine holds the built `%User{}`, exactly as before.
    #  * Queued inbox entries are appended by the executor's
    #    `{:drain_inbox, :append}` shape, which builds the combined message and
    #    consumes it **without** `start_chat/3`. Under peek-then-consume (#26)
    #    a drain that needed a compaction left its entries queued, so a bare
    #    `{:drain_inbox}` would re-preflight them and re-`stage/3` the failing
    #    compaction — the loop the ack exists to break. It stays the shape for
    #    "nothing held and nothing queued", i.e. the empty-inbox no-op.
    actions =
      case {held_user(m), Boundary.inbox_count(m.work.ctx)} do
        {nil, 0} -> [{:drain_inbox}]
        {nil, _queued} -> [{:drain_inbox, :append}]
        {user, 0} -> [{:append, {:user, user}}, {:drain_inbox}]
        {user, _queued} -> [{:append, {:user, user}}, {:drain_inbox, :append}]
      end

    Phase.rest(
      %{m | loop_count: 0, pending_user_message: nil, mid_turn_entry: nil},
      :chat,
      :loop_breaker,
      actions
    )
  end

  # --- blocked-enter / unblocked (before the generic blocked catch-all) ---

  def do_step(%Machine{} = m, {:blocked, phase, _reason}) when phase in @blocked do
    Phase.block(m, phase, :blocked, [])
  end

  def do_step(%{phase: p} = m, {:unblocked}) when p in @blocked do
    Phase.rest(m, :chat, :unblocked, [{:drain_inbox}])
  end

  # Blocked phases reject ordinary work until an exit event unsticks them.
  def do_step(%{phase: p} = m, _event) when p in @blocked, do: {:ignore, :blocked, m}

  # A successful outbound `agents-send` discharges the debt to the agent it
  # reached (issue #31 §1.4). The tool worker sends this from its own process
  # *before* its `{:tool_results, …}`, so mailbox order puts the clear ahead of
  # the response that settles the turn: the idle gate can never remind for a
  # reply already in flight. Accepted in every non-blocked phase; a blocked
  # agent's turn is over, so the block owns that debt's disposition.
  def do_step(%Machine{} = m, {:reply_sent, sender}),
    do: {:ok, [], Machine.discharge_reply(m, sender)}

  # --- stop ---

  # The stop itself, its two no-op guards, and the single terminal transition
  # its timer owns all live in `Machine.Stopping` (issue #36, step 4): a stop now
  # kills every backgrounded batch and records the cancellation, which does not
  # fit beside the transition table's line cap.
  def do_step(%Machine{} = m, {:stop, channel}), do: Stopping.stop(m, channel)
  def do_step(%{phase: :stopping} = m, :stop_timer), do: Stopping.stop_timer(m)

  # A record the appender refused before the timer was armed. It is handled only
  # in that window: once the timer is armed a refusal is the ordinary
  # catch-all's business, and `Machine.Stopping` re-arms the timer for the case
  # where the refused append was what stood between the stop and its timer.
  def do_step(%{phase: :stopping, stop_timer: nil} = m, {:append_result, outcome, reason}),
    do: Stopping.record_refused(m, outcome, reason)

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

  # --- idle ---

  def do_step(%{phase: :idle} = m, {:chat_request, entry}), do: start_chat(m, entry, nil)

  # A manual `/compact [focus]`. The user asked for it, so reset the
  # consecutive-compaction counter before staging: three back-to-back manual
  # requests are deliberate, not the automatic loop the breaker guards against.
  # The optional `focus` rides on `work` into `Dispatch.compaction_plan/1`.
  def do_step(%{phase: :idle} = m, {:compact_request, focus}) do
    Compaction.stage(%{m | loop_count: 0, work: %{m.work | focus: focus}}, nil, nil)
  end

  def do_step(%{phase: :idle} = m, {:inbox_drain, entries, content}),
    do: deliver_inbox(m, entries, content)

  def do_step(%{phase: :idle} = m, {:http_ok, _ref, _response}), do: {:ignore, :stale_result, m}

  def do_step(%{phase: :idle} = m, {:tool_results, _ref, _results}),
    do: {:ignore, :stale_result, m}

  def do_step(%{phase: :idle} = m, :iterate), do: {:ignore, :not_applicable, m}
  def do_step(%{phase: :idle} = m, :stop_timer), do: {:ignore, :not_applicable, m}

  def do_step(%{phase: :idle} = m, {:append_result, :invalid, reason}) do
    Failure.fail_turn(m, %ArgumentError{message: reason}, [])
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
        actions = [{:append_many, pair}, {:drain_inbox}]

        Phase.rest(
          %{m | work: %{m.work | pending_notice: nil}},
          :chat,
          :workspace_notice,
          actions
        )

      :needs_compaction ->
        Compaction.stage(m, nil, nil)

      :cannot_compact ->
        actions = [{:broadcast, {:overflow, :reserve_exhausted, "start a conversation"}, nil}]

        Phase.block(
          %{m | work: %{m.work | pending_notice: nil}},
          :context_overflow,
          :workspace_notice,
          actions
        )
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
      Phase.rest(clear_worker(m), :chat, :llm_error, [{:llm_error, msg}, {:drain_inbox}])
    else
      {:ignore, :stale_result, m}
    end
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:http_error, ref, reason}) do
    if valid_ref?(m, ref), do: Failure.fail_turn(m, reason, []), else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:worker_crashed, ref, exception, st}) do
    if valid_ref?(m, ref),
      do: Failure.fail_turn(m, exception, st),
      else: {:ignore, :stale_result, m}
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

  # The boundary delivery (issue #15): a drained inbox message lands here as a
  # user turn and the turn continues in place — the same body as the `:idle`
  # clause, but the phase stays `:generating`, so no transient idle is ever
  # broadcast (an idle-based `agents-wait` would resolve early, and a
  # `{:finalize, :clean}` would report a partial result to a parent).
  def do_step(%{phase: :generating, kind: :chat} = m, {:inbox_drain, entries, content}),
    do: deliver_inbox(m, entries, content)

  def do_step(%{phase: :generating, kind: :chat} = m, {:append_result, :invalid, reason}) do
    Failure.fail_turn(m, %ArgumentError{message: reason}, [])
  end

  def do_step(%{phase: :generating, kind: :chat} = m, {:append_result, :stale, _}),
    do: {:ignore, :stale_append, m}

  def do_step(%{phase: :generating, kind: :chat} = m, {:tool_results, _ref, _results}),
    do: {:ignore, :stale_result, m}

  # --- executing tools ---

  # A message that arrived while the batch was executing (issue #36):
  # `Machine.Backgrounding` moves the batch to the background, answers its calls
  # with a synthetic result, and continues the turn with the delivered message.
  # Not backgroundable — no live worker, nothing left to answer, or a delivery
  # that would not fit the context — is a no-op that leaves the entries queued
  # for the turn boundary, so the boundary's own compaction/block decision is
  # the one that runs for them.
  def do_step(%{phase: :executing_tools} = m, {:inbox_drain, entries, content}),
    do: Backgrounding.step(m, entries, content)

  def do_step(%{phase: :executing_tools} = m, {:tool_results, ref, results}) do
    if valid_ref?(m, ref), do: tool_results(m, results), else: {:ignore, :stale_result, m}
  end

  def do_step(%{phase: :executing_tools} = m, {:append_result, :invalid, reason}) do
    Failure.fail_turn(m, %ArgumentError{message: reason}, [])
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

  # The staged compaction request was assembled; spawn the compactor.
  def do_step(%{phase: :generating, kind: :compaction} = m, :iterate) do
    messages = Dispatch.request_messages(m)

    case Preflight.validate_request(messages) do
      :ok ->
        provisional = m.work.active_message_index
        ctx = Dispatch.spawn_ctx(m, messages)
        {:ok, [{:set_streaming, provisional}, {:stage_compaction, ctx}], m}

      {:error, violations} ->
        Compaction.compaction_failed(
          m,
          Preflight.format_violations(violations),
          Compaction.carried(m)
        )
    end
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

  # Both `{:inbox_drain, …}` boundaries — `:idle` and the `:generating`/`:chat`
  # turn boundary from issue #15 — start the delivered message's turn the same
  # way: build the user message in the current mode and hand it to
  # `start_chat/3`, which owns the fits / compaction / block decision. The
  # message carries the batch's fulfilled ids (`Inbox.build_drained_message/3`):
  # the notice answers the backgrounded calls it names, which is what lets a
  # later load tell a kept promise from a lost one.
  defp deliver_inbox(m, entries, content) do
    user = Inbox.build_drained_message(entries, content, m.work.ctx.mode)
    start_chat(m, {:user_message, user}, entries)
  end

  # `inbox_entries` is the batch the drain *peeked* (issue #26): the executor
  # leaves `state.live.inbox` untouched, so the entries stay queued (and on the
  # wire) until this branch consumes them. `nil` is the human
  # `{:chat_request, …}` path, which has no queue behind it.
  defp start_chat(m, entry, inbox_entries) do
    user = unwrap_user(entry)
    limit = m.work.ctx.context_limit

    case Dispatch.preflight_decision(Delivery.projected(m, [], user), limit) do
      :fits ->
        # The action assembly (the notice, the reply debt, the consume, the
        # `:iterate`) is shared with the backgrounding path — `Machine.Delivery`.
        # No `pre` batch here: the delivered message is the only append.
        {actions, m} = Delivery.fits(m, [], inbox_entries, user)
        {:ok, actions, init_turn(enter(m, :chat, :generating, :http), entry)}

      :needs_compaction ->
        # Only the chat-request path parks. The drain path keeps its entries
        # queued (peek-then-consume), so the compaction's `resume/1` re-drains
        # them in place once the context has shrunk.
        parked = if inbox_entries in [nil, []], do: %{m | pending_user_message: entry}, else: m
        Compaction.stage(parked, nil, nil)

      :cannot_compact ->
        # The drained entries stay queued (nothing consumed them) and the agent
        # blocks; `{:unblocked}`'s `{:drain_inbox}` re-attempts them once the
        # operator has acted.
        actions = [{:broadcast, {:overflow, :reserve_exhausted, "start a conversation"}, nil}]
        Phase.block(m, :context_overflow, :cannot_compact, actions)
    end
  end

  # --- iterate / dispatch ---

  defp iterate(m) do
    case MessageList.unpaired_tail_tool_uses(messages(m)) do
      # Deliver queued inbox entries instead of dispatching when nothing is in
      # flight (issue #15). The rule, and why this position inside the `[]`
      # branch is load-bearing, live in `Machine.Boundary`. Returning the
      # machine unchanged keeps the phase `:generating`, so the executor's
      # follow event starts the delivered message's turn in place.
      [] ->
        if Boundary.drain?(m), do: {:ok, [{:drain_inbox}], m}, else: dispatch_http(m)

      uses ->
        preflight_pending_tools(m, uses)
    end
  end

  defp dispatch_http(m) do
    case Preflight.validate_request(messages(m)) do
      :ok ->
        do_dispatch_http(m)

      {:error, violations} ->
        Failure.fail_turn(m, %ArgumentError{message: Preflight.format_violations(violations)}, [])
    end
  end

  defp do_dispatch_http(m) do
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

  # The compactor's own worker that dies without delivering a result is a
  # compaction failure, not a turn crash (the same retryable path as
  # `:http_error`/`:worker_crashed` for the compactor); any other pid falls to
  # the turn's own-worker identity test.
  defp worker_down(%{kind: :compaction} = m, pid, reason) do
    if is_pid(pid) and pid == m.work.active_worker do
      Compaction.compaction_failed(m, reason, Compaction.carried(m))
    else
      {:ignore, :unknown_worker_down, m}
    end
  end

  defp worker_down(m, pid, reason), do: Failure.worker_down(m, pid, reason)

  # A pid the backgrounded map does not own keeps the blocked catch-all's
  # precedence, which the clause above would otherwise preempt: a block clears
  # only `worker_kind` (`Phase.enter_blocked/2`), so a compaction that blocked on
  # `:compaction_failed` still holds its worker's pid, and its `:DOWN` would
  # re-run `compaction_failed/3` — a second `{:compaction_error}` broadcast for a
  # failure the block has already reported. The catch-all answers
  # `{:ignore, :blocked, _}` for every other event, and it has always answered
  # that for this one.
  defp unowned_worker_down(%{phase: p} = m, _pid, _reason) when p in @blocked,
    do: {:ignore, :blocked, m}

  defp unowned_worker_down(m, pid, reason), do: worker_down(m, pid, reason)

  defp valid_ref?(m, ref) do
    not Machine.stopping?(m) and is_reference(m.work.worker_ref) and m.work.worker_ref == ref
  end

  defp messages(m), do: m.work.ctx.messages

  # A child's outcome is delivered into this agent's own inbox (§2.1). When the
  # machine is already idle, nothing else would ever drain it: a peer's message
  # wakes an idle agent (`Inbox.handle_delivery/4` drains it), and a child's
  # answer has to as well — otherwise a parent that ended its turn before its
  # child answered would leave the answer sitting in the queue until something
  # else woke it. While the parent is `:generating` the `:iterate` turn boundary
  # drains it instead. `:executing_tools` needs the drain too (issue #36): an
  # internal enqueue never passes through the delivery path, so this is the only
  # thing that can background the parent's batch and deliver the answer now.
  defp child_event(m, event) do
    case Children.step(m.children, event) do
      {:ok, actions, children} ->
        actions = actions ++ [{:broadcast, :status, nil}]

        drain = if m.phase in [:idle, :executing_tools], do: [{:drain_inbox}], else: []
        {:ok, actions ++ drain, %{m | children: children}}

      {:ignore, reason, children} ->
        {:ignore, reason, %{m | children: children}}
    end
  end
end
