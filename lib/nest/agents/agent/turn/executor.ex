defmodule Nest.Agents.Agent.Turn.Executor do
  @moduledoc """
  The single place the Agent's turn work causes effects.

  `Machine.step/2` is pure and returns a list of actions. This module runs
  them, in order, against the live Agent state. It owns every effect a turn
  performs: sequence appends, worker spawns, timer arm/cancel, channel acks,
  broadcasts, usage merges, inbox drains, reply give-ups, and sub-agent
  notifications.

  Some facts only exist after an effect runs (an append's tagged result, a
  preflight decision, a spawned worker's pid/ref). `run_all/2` executes until
  an action produces a follow-up event, then returns it so the settle loop can
  feed it back through `Machine.step/2`: that round trip keeps `step/2` pure
  while still reacting to the real world.

  `:iterate` is deliberately deferred through the mailbox (never run
  inline): the old driver advanced a turn with `send(self(), :iterate)`,
  and keeping that boundary preserves the async timing of worker spawns.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction.Overflow
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler.FileAccess
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.Timeline
  alias Nest.Agents.Agent.ToolFilter
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Agent.Turn.Commit
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.Turn.GiveUpDelivery
  alias Nest.Agents.Agent.Turn.HTTPWorker
  alias Nest.Agents.Agent.Turn.Terminal
  alias Nest.Messages.Streaming
  alias Nest.Messages.ThinkTags
  alias Nest.Tokens.Compactor, as: TokensCompactor
  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  @doc """
  Run actions in order until one yields a follow-up event (or the list is
  exhausted). Returns `{state, follow_up_event | nil}`.
  """
  @spec run_all([term()], Agent.t()) :: {Agent.t(), term() | nil}
  def run_all(actions, state) do
    Enum.reduce_while(actions, {state, nil}, fn action, {state, nil} ->
      case execute(action, state) do
        {state, :continue} -> {:cont, {state, nil}}
        {state, {:follow, event}} -> {:halt, {state, event}}
      end
    end)
  end

  # A turn advance is a mailbox deferral, matching the old driver.
  defp execute(:iterate, state) do
    send(self(), :iterate)
    {state, :continue}
  end

  # Any other bare-atom action is a follow-up event fed back to `step/2`.
  defp execute(event, state) when is_atom(event), do: {state, {:follow, event}}

  defp execute({:log, level, message}, state) do
    case level do
      :warning -> Logger.warning(message)
      :info -> Logger.info(message)
      _ -> Logger.error(message)
    end

    {state, :continue}
  end

  defp execute({:broadcast, :status, _}, state) do
    Broadcasts.status(state)
    {state, :continue}
  end

  defp execute({:merge_metrics, usage}, state) do
    Timeline.usage(state, usage)

    # The usage totals merge; the status broadcast (with the updated chip)
    # is emitted by the settle loop after the turn's effects land.
    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | usage_totals: Broadcasts.merge_usage_totals(state.llm_metrics.usage_totals, usage)
        }
    }

    {state, :continue}
  end

  defp execute({:set_crossed_thresholds, set}, state) do
    {%{state | live: %{state.live | crossed_thresholds: set}}, :continue}
  end

  defp execute({:set_context_projection, n}, state) when is_integer(n) and n >= 0 do
    {%{state | live: %{state.live | context_projection: n}}, :continue}
  end

  defp execute({:set_context_projection, _}, state), do: {state, :continue}

  defp execute({:set_api_log_sequences, sequences}, state) do
    {%{state | live: %{state.live | api_log_sequences: sequences}}, :continue}
  end

  defp execute({:set_cancelled, value}, state) do
    {%{state | live: %{state.live | cancelled: value}}, :continue}
  end

  defp execute({:set_streaming, index}, state) do
    acc = Streaming.new(index)

    state = %{state | live: %{state.live | streaming_acc: acc, tool_index_map: %{}}}
    {state, :continue}
  end

  defp execute({:ack, pid, term}, state) when is_pid(pid) do
    send(pid, term)
    {state, :continue}
  end

  defp execute({:kill, pid}, state) when is_pid(pid) do
    # BEAM FIFO ordering guarantees the stop message is processed before
    # the kill when the worker is in BEAM code.
    send(pid, {:stop_chat, self()})
    Process.exit(pid, :kill)
    {state, :continue}
  end

  defp execute({:kill, _ref}, state), do: {state, :continue}

  defp execute({:cancel_timer, ref}, state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    {state, :continue}
  end

  defp execute({:cancel_timer, _}, state), do: {state, :continue}

  defp execute({:arm_timer, ms, :stop_timer}, state) do
    ref = Process.send_after(self(), :stop_timer, ms)
    {state, {:follow, {:timer_armed, :stop_timer, ref}}}
  end

  defp execute({:append, message}, state) do
    result = MessageAppender.handle_single(state, message)

    case result do
      {:ok, _stamped, state} -> {state, :continue}
      {:stale, state} -> {state, {:follow, {:append_result, :stale, nil}}}
      {:invalid, reason, state} -> {state, {:follow, {:append_result, :invalid, reason}}}
    end
  end

  defp execute({:append_many, messages}, state) do
    case MessageAppender.append_in_process(state, messages) do
      {:ok, _stamped, state} -> {state, :continue}
      {:stale, state} -> {state, {:follow, {:append_result, :stale, nil}}}
      {:invalid, reason, state} -> {state, {:follow, {:append_result, :invalid, reason}}}
    end
  end

  defp execute({:record_file_access}, state) do
    case List.last(state.chat_state.messages) do
      nil -> {state, :continue}
      stamped -> {record_file_access(stamped, state), :continue}
    end
  end

  defp execute({:preflight, ctx, calls, _continuation}, state) do
    decision =
      case BatchSizer.preflight(calls, ctx) do
        :fits -> :fits
        {:refuse, reason} -> {:refuse, reason}
      end

    {state, {:follow, {:preflight_result, decision}}}
  end

  defp execute({:spawn_http, ctx}, state) do
    Timeline.llm_request(state, ctx)

    spawn_worker(state, :http, fn ref, pid ->
      Process.put(:"$callers", [pid])
      HTTPWorker.run(ctx, ref)
    end)
  end

  defp execute({:spawn_tools, ctx, calls}, state) do
    spawn_worker(state, :tools, fn ref, agent_pid ->
      Process.put(:"$callers", [agent_pid])
      results = ToolLoop.execute(ctx, %{}, calls)
      send(agent_pid, {:tool_results, ref, results})
    end)
  end

  defp execute({:stage_compaction, ctx}, state) do
    Timeline.compaction_staged(state, ctx)

    spawn_worker(state, :http, fn ref, pid ->
      Process.put(:"$callers", [pid])
      HTTPWorker.run(ctx, ref)
    end)
  end

  defp execute({:commit_compaction, data}, state), do: commit_compaction(state, data)

  defp execute({:finalize, :clean}, state) do
    state = clear_live(state)
    send_parent(state, Terminal.parent_completion(state))
    {state, :continue}
  end

  defp execute({:finalize, metadata}, state) when is_map(metadata) do
    state = finalize_partial(state, metadata)
    state = clear_live(state)
    send_parent(state, Terminal.parent_failure(state, :stopped))
    {state, :continue}
  end

  defp execute({:fail_turn, reason, stacktrace}, state) do
    state = finalize_partial(state, Terminal.error_metadata())
    state = clear_live(state)

    if Terminal.benign_crash?(reason) do
      send_parent(state, Terminal.parent_failure(state, Terminal.crash_reason(reason)))
      {state, :continue}
    else
      Logger.error(fn ->
        "[agent:#{state.name}] chat_crashed msg_index=#{state.chat_state.next_message_index} ::\n" <>
          Exception.format(:error, reason, stacktrace)
      end)

      Broadcasts.error(
        state.space_id,
        state.name,
        state.chat_state.next_message_index,
        crash_text(reason, stacktrace),
        "Turn.run/2"
      )

      send_parent(state, Terminal.parent_failure(state, Terminal.crash_reason(reason)))
      {state, :continue}
    end
  end

  # A stream error persists the partial + error text as the assistant
  # message (not a sequence repair), broadcasts `chat:error`, and idles.
  defp execute({:llm_error, error_msg}, state) do
    message = Terminal.error_assistant_message(state, error_msg)

    case MessageAppender.handle_single(state, message) do
      {:ok, stamped, state} ->
        index = Nest.Agents.Agent.stamped_index(stamped)
        state = clear_live(state)
        Broadcasts.error(state.space_id, state.name, index, error_msg, "Turn.run/2")
        {state, :continue}

      {:stale, state} ->
        {clear_live(state), :continue}

      {:invalid, reason, state} ->
        Logger.error("[agent:#{state.name}] dropping an invalid stream-error append: #{reason}")
        {clear_live(state), :continue}
    end
  end

  # A child's outcome is delivered here, in the parent's process, so a child
  # whose worker is already gone cannot lose the result — there is no `send/2`
  # to a pid left to fail (issue #31 §2.1). It goes to the child's *reporting
  # target* when it has one that is still alive: a batch child reports to its
  # coordinator, so the parent reads the batch's aggregate once instead of every
  # child's answer as well. A target that has died falls back to the parent's
  # own inbox, so a batch whose coordinator crashed degrades to per-child
  # messages rather than to silence. The completion arrives as the child's own
  # words; a child that produced nothing, failed, or was stopped arrives as a
  # runtime notice.
  defp execute({:child_message, name, result}, state) do
    Timeline.child_message(state, name, result)

    case Children.target(state.live.machine.children, name) do
      target when is_pid(target) ->
        if Process.alive?(target) do
          send(target, {:child_message, name, result})
          {state, :continue}
        else
          enqueue_child_message(state, name, result)
        end

      nil ->
        enqueue_child_message(state, name, result)
    end
  end

  defp execute({:merge_usage, name, usage}, state) do
    Timeline.child_usage(state, name, usage)

    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | descendant_usage: Broadcasts.total_usage(state.llm_metrics.descendant_usage, usage)
        }
    }

    {state, :continue}
  end

  defp execute({:stop_child, name}, state) do
    Timeline.child_action(state, "stopped", name)
    _ = Nest.Agents.Supervisor.stop_agent(state.space_id, name)
    {state, :continue}
  end

  defp execute({:archive_child, name}, state) do
    Timeline.child_action(state, "archived", name)
    _ = Nest.Agents.Supervisor.archive_agent(state.space_id, name)
    {state, :continue}
  end

  defp execute({:stop_all_children}, state), do: {stop_running_children(state), :continue}

  defp execute({:drain_inbox}, state) do
    case peek_inbox(state) do
      :empty -> {state, :continue}
      {state, batch, content} -> {state, {:follow, {:inbox_drain, batch, content}}}
    end
  end

  # The loop breaker's give-up shape (issue #26): build the message from the
  # peeked batch, append it, and consume it — without `start_chat/3`, so the ack
  # cannot re-enter the compaction decision it just gave up on (the
  # `{:append, {:user, _}}` arm's shape, for a parked chat request).
  defp execute({:drain_inbox, :append}, state) do
    case peek_inbox(state) do
      :empty ->
        {state, :continue}

      {state, batch, content} ->
        user = Dispatch.build_user_message(content, state.live.mode)

        # `:stale` is the appender's "this message does not answer the live
        # sequence" refusal. Consuming the batch on it would drop the message
        # with nothing in the transcript — the "in neither" state #26 exists to
        # eliminate — so the batch stays queued and the refusal rides back as a
        # follow event, exactly as the `{:append, _}` clause's failure does.
        case MessageAppender.handle_single(state, user) do
          {:ok, _stamped, state} -> consume_inbox(state, batch)
          {:stale, state} -> {state, {:follow, {:append_result, :stale, nil}}}
          {:invalid, reason, state} -> {state, {:follow, {:append_result, :invalid, reason}}}
        end
    end
  end

  # The consume half of peek-then-consume, emitted by the branch that actually
  # appended the message (issue #26).
  defp execute({:consume_inbox, entries}, state), do: consume_inbox(state, entries)

  # The reply give-up (issue #31 §1.6): the agent is settling or blocking while it
  # still owes a reply, so each requester is told no answer is coming and the debt
  # is discharged. The resting funnel (`Machine.Phase.rest/4` / `block/4`) is the
  # only emitter of the action.
  defp execute({:give_up_replies, reason}, state) do
    case Machine.owed_senders(state.live.machine) do
      [] ->
        {state, :continue}

      senders ->
        # The give-up is recorded before the notices are attempted: the
        # decision is the event, and a notice that could not be delivered is
        # its own `give_up_refused` line next to it.
        Timeline.gave_up(state, senders, reason)
        GiveUpDelivery.deliver(state, senders, reason)
        {put_machine(state, Machine.discharge_all(state.live.machine)), :continue}
    end
  end

  defp execute({:broadcast, :compaction, marker}, state) do
    Broadcasts.compaction(state, marker)
    {state, :continue}
  end

  defp execute({:broadcast, {:notification, payload}, _}, state) do
    Broadcasts.notification(state.space_id, state.name, payload)
    {state, :continue}
  end

  defp execute({:broadcast, {:error, index, msg}, _}, state) do
    Broadcasts.error(state.space_id, state.name, index, msg)
    {state, :continue}
  end

  defp execute({:broadcast, {:compaction_error, msg}, _}, state) do
    source = "Nest.Agents.Agent.Turn.Executor"
    Broadcasts.compaction_error(state, msg, source)
    {state, :continue}
  end

  defp execute({:broadcast, {:compaction_loop, reason, count, max}, _}, state) do
    source = "Nest.Agents.Agent.Turn.Executor"
    Broadcasts.compaction_loop(state.space_id, state.name, reason, source, count, max)
    {state, :continue}
  end

  defp execute({:broadcast, {:overflow, reason, verb}, _}, state) do
    Overflow.broadcast(state, "Turn.Executor", verb, nil, reason)
    {state, :continue}
  end

  # Backstop for drift: an action the machine emitted with no clause must
  # never crash the Agent. The guard tests assert every declared action
  # has a clause; this logs loudly and moves on if that ever breaks.
  defp execute(other, state) do
    Logger.error("[turn executor] unknown turn action: #{inspect(other)}")
    {state, :continue}
  end

  # --- helpers ---

  # The peek half of peek-then-consume (issue #26): the drain computes the
  # batch's content and applies its mode, but leaves `state.live.inbox` alone and
  # rebroadcasts nothing. `{:consume_inbox, _}` is what clears the queue —
  # emitted only by the branch that appended the message — so a delivery that
  # parks (a compaction, a block) leaves the message queued and visible.
  defp enqueue_child_message(state, name, result) do
    {content, kind} = SubAgentResults.child_message(name, result)
    {Inbox.enqueue_internal(state, name, content, kind), :continue}
  end

  defp peek_inbox(state) do
    case Inbox.batch(state.live.inbox) do
      [] ->
        :empty

      batch ->
        content = Inbox.combine_and_offload(batch, state)
        mode = applied_mode(state, batch)
        mode_changed? = mode != state.live.mode
        state = %{state | live: %{state.live | mode: mode}}

        # `Broadcasts.status/1` is the only carrier of `currentMode`, and the
        # settle loop broadcasts only on a status *change* — which this drain
        # deliberately does not cause (the phase stays `:generating`) — so the
        # new mode is published here or the UI keeps the old one until the turn
        # ends.
        if mode_changed?, do: Broadcasts.status(state)

        {state, batch, content}
    end
  end

  defp consume_inbox(state, entries) do
    # Drop exactly the peeked batch, not the whole queue: the executor runs
    # synchronously inside one settle, so nothing can be enqueued between the
    # peek and the consume, and anything the peek did not deliver stays queued.
    inbox = state.live.inbox -- entries
    state = %{state | live: %{state.live | inbox: inbox}}
    Broadcasts.inbox(state, Inbox.serialize(inbox))
    Timeline.drained(state, entries)
    {state, :continue}
  end

  # One mode per delivered batch: the most recent human-sourced entry that
  # carries a mode wins (`Inbox.drain_mode/1`), and the agent's current mode
  # stands when no entry does. The winner is resolved against the vocation
  # exactly as `ChatPipeline.handle_chat/3` resolves an idle turn's request, so
  # `state.live.mode` — and with it the UI's `currentMode` — never holds a mode
  # the vocation does not define. Applied here, never when the entry was queued:
  # `state.live.mode` feeds `ctx.mode`/`ctx.caps`, which `Turn.prepare/1`
  # rebuilds on every settle, so setting it on arrival would re-resolve the caps
  # of the *ongoing* turn's remaining tool calls.
  defp applied_mode(state, entries) do
    case Inbox.drain_mode(entries) do
      nil ->
        state.live.mode

      requested ->
        {resolved, _caps} =
          ChatPipeline.resolve_mode_and_caps(
            requested,
            state.vocation,
            state.workspace_path,
            state.tmp_path
          )

        resolved
    end
  end

  defp spawn_worker(state, kind, fun) do
    ref = make_ref()
    agent_pid = self()

    case Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
           # Wait for the executor's go-ahead so the monitor is established
           # while the worker is still alive: otherwise a worker that dies at
           # once yields a `:noproc` DOWN instead of its real exit reason.
           receive do
             {:worker_go, ^ref} -> :ok
           after
             5_000 -> exit(:no_worker_go)
           end

           fun.(ref, agent_pid)
         end) do
      {:ok, pid} ->
        Process.monitor(pid)
        send(pid, {:worker_go, ref})
        {state, {:follow, {:worker_started, ref, pid, kind}}}

      _other ->
        {state, {:follow, {:worker_crashed, ref, %RuntimeError{message: "saturated"}, []}}}
    end
  end

  defp finalize_partial(state, metadata) do
    state
    |> Terminal.recovery_messages(metadata)
    |> Enum.reduce(state, &append_recovery/2)
  end

  defp append_recovery(message, state) do
    case MessageAppender.handle_single(state, message) do
      {:ok, _stamped, state} ->
        state

      {:stale, state} ->
        state

      {:invalid, reason, state} ->
        Logger.error(
          "[agent:#{state.name}] dropping an invalid terminal recovery append: #{reason}"
        )

        state
    end
  end

  defp clear_live(state) do
    %{
      state
      | live: %{
          state.live
          | streaming_acc: nil,
            cancelled: false,
            tool_index_map: %{},
            context_projection: nil
        }
    }
  end

  defp error_message(%{__exception__: true} = ex), do: Exception.message(ex)
  defp error_message(other), do: inspect(other)

  # The user-facing crash text: the exception message plus a short
  # stacktrace snippet (the frames help pinpoint where the crash was).
  defp crash_text(reason, []), do: error_message(reason)
  defp crash_text(reason, stacktrace), do: Terminal.format_crash(reason, stacktrace)

  defp send_parent(%{tree_position: %{parent_name: nil}}, _payload), do: :ok

  defp send_parent(state, payload) do
    GenServer.cast(
      Nest.Agents.Registry.via_tuple(state.space_id, state.tree_position.parent_name),
      payload
    )
  end

  defp stop_running_children(state) do
    machine = state.live.machine

    machine
    |> Machine.running_child_names()
    |> Enum.each(fn name -> _ = Nest.Agents.Supervisor.stop_agent(state.space_id, name) end)

    put_machine(state, %{machine | children: %Children{}})
  end

  defp put_machine(state, machine), do: %{state | live: %{state.live | machine: machine}}

  defp record_file_access(stamped, state) do
    FileAccess.record(stamped, state)
  end

  # --- compaction commit ---

  defp commit_compaction(state, data) do
    summary_text = ThinkTags.strip(data.summary_text)

    case TokensCompactor.validate_summary(summary_text) do
      :ok -> do_commit(state, summary_text, data)
      {:error, reason} -> {state, {:follow, {:commit_error, reason}}}
    end
  end

  defp do_commit(state, summary_text, data) do
    state =
      state
      |> reset_crossed_thresholds()
      |> reset_context_projection()
      |> reset_read_files()

    {state, system_prompt} = refresh_vocation_and_tools(state)

    case MessageAppender.append_in_process(state, data.staged ++ [data.summary_assistant]) do
      {:ok, _stamped, state} -> commit_active_segment(state, summary_text, data, system_prompt)
      {:invalid, reason, state} -> {state, {:follow, {:commit_error, reason}}}
    end
  end

  defp commit_active_segment(state, summary_text, data, system_prompt) do
    marker_index = state.chat_state.next_message_index
    archived_count = length(state.chat_state.messages || [])

    {new_messages, marker} =
      Commit.active_segment(
        state,
        summary_text,
        data.carried_entry,
        marker_index,
        archived_count,
        system_prompt
      )

    Timeline.compaction_committed(state, marker_index, new_messages)
    state = archive_active_segment(state)

    with {:ok, _marker, state} <- MessageAppender.append_marker(state, marker),
         {:ok, _stamped, state} <- MessageAppender.append_in_process(state, new_messages) do
      Broadcasts.compaction(state, marker)
      Logger.info("Compaction complete: agent=#{state.name} carried=#{data.carried_entry != nil}")
      {state, {:follow, {:commit_done}}}
    else
      {:invalid, reason, state} -> {state, {:follow, {:commit_error, reason}}}
    end
  end

  defp refresh_vocation_and_tools(state) do
    fresh_vocation = fetch_fresh_vocation(state)

    {system_prompt, _mode, tool_names, fresh_vocation} =
      SystemPrompt.compose_vocation_config(
        fresh_vocation,
        state.workspace_path,
        {state.llm_metrics.context_limit, state.llm_metrics.context_limit_source},
        state.name,
        state.depth
      )

    tool_names = ToolFilter.exclude_spawn_at_max_depth(tool_names, state.depth)
    tools = Nest.Tools.get_functions(tool_names, state.workspace_path, state.tmp_path)

    {%{state | vocation: fresh_vocation, tools: tools}, system_prompt}
  end

  defp fetch_fresh_vocation(state) do
    case Vocations.get_vocation(state.vocation_id) do
      %Vocation{} = v -> v
      nil -> state.vocation
    end
  rescue
    _ in [DBConnection.OwnershipError] ->
      state.vocation

    error ->
      Logger.warning("Vocation lookup failed during compaction: #{inspect(error)}")
      state.vocation
  end

  defp archive_active_segment(state) do
    %{state | chat_state: %{state.chat_state | messages: []}}
  end

  defp reset_crossed_thresholds(state),
    do: %{state | live: %{state.live | crossed_thresholds: MapSet.new()}}

  defp reset_context_projection(state),
    do: %{state | live: %{state.live | context_projection: nil}}

  defp reset_read_files(state),
    do: %{state | chat_state: %{state.chat_state | read_files: %{}}}
end
