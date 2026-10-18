defmodule Nest.Agents.Agent.Callbacks do
  @moduledoc """
  GenServer callback dispatch for `Nest.Agents.Agent`.

  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays under the credo 500-line cap. Each `handle_call/3`,
  `handle_cast/2`, and `handle_info/2` clause lives here; the
  `Agent` module exposes a single delegating clause per
  shape so the GenServer behavior remains on the `Agent`
  module itself.

  The handler bodies here are unchanged from their previous
  location in `agent.ex`. They reference the agent's state
  struct (`%Agent{}`) by full module path inside Callbacks to
  avoid an `alias` cycle with `Agent`.
  """

  require Logger

  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.IntrospectionHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Watch
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.Agents.SpaceGate
  alias Nest.Persistence

  # The space's environment changed (`Nest.Spaces.update_environment/2`): the
  # workspace, the network access and the backend, all three.
  #
  # `WorkspaceHandler` moves the mounts, rebuilds the tool closures from them and
  # appends the notice pair — after a preflight check, so a conversation that
  # needs compaction defers the notice rather than dropping it. The system prompt
  # is deliberately not rebuilt (prefix cache), which is why the notice exists.
  #
  # Nothing is refused and nothing waits: the values are the *space's*. The notice
  # is appended, not queued: appending costs no turn, while queueing would defer
  # it to the agent's next one — and a space edit must not cost an LLM call per
  # live agent.
  #
  # A machine that is mid-turn cannot take the notice (see
  # `WorkspaceHandler.apply_space_environment/2`), and then the flag stays set so
  # the change is announced at the agent's next start instead of being lost.
  def handle_cast({:space_changed, values}, state) do
    {state, outcome} =
      WorkspaceHandler.apply_space_environment(state, to_mounts_values(values))

    {:noreply, maybe_clear_space_notice(state, outcome)}
  end

  # A tool worker's "my `agents-send` reached its target": a turn event for this
  # agent, translated by `Turn.handle/2` like the other worker results. The
  # worker casts it *before* its `{:tool_results, …}`, so the debt is discharged
  # before the response that settles the turn (issue #31 §1.4).
  def handle_cast({:reply_sent, sender}, state) do
    Turn.handle({:reply_sent, sender}, state)
  end

  # The watcher task's pid, once it is up (issue #54). A task that could not be
  # started is unregistered instead, so no watch is left pointing at nothing.
  def handle_cast({:watch_attached, ref, pid}, state) do
    {:noreply, Watch.attach(state, ref, pid)}
  end

  def handle_cast({:unregister_watch, ref}, state) do
    {:noreply, Watch.unregister(state, ref)}
  end

  # Sub-agent: child finished its turn. Merge usage, drop the
  # pending-child entry, forward the result, broadcast status.
  def handle_cast({:child_completed, child_name, response, child_total_usage}, state) do
    SubAgent.handle_child_completed(state, child_name, response, child_total_usage)
  end

  # Sub-agent: child ended its turn without a normal completion
  # (chat crash or user Stop). Fail the blocked worker's slot
  # immediately instead of waiting out the per-item timeout.
  def handle_cast({:child_failed, child_name, reason}, state) do
    SubAgent.handle_child_failed(state, child_name, reason)
  end

  # Sub-agent: a registered child process died before completing
  # (crash, Stop, external archive, cascade teardown). Same
  # fail-fast handling as `:child_failed`.
  def handle_cast({:child_terminated, child_name, reason}, state) do
    SubAgent.handle_child_terminated(state, child_name, reason)
  end

  # Compatibility entry point for a `{:chat_stopped, _}` cast. The
  # in-process turn finalizes through the stop timer and does not cast
  # this; the sub-agent cascade tests drive it directly to exercise the
  # child-teardown path. `handle_cast` doesn't route through `Handlers`,
  # so we settle the stop directly via `Turn.settle/2`.
  def handle_cast({:chat_stopped, from}, state) do
    {:ok, state} = Turn.settle(state, {:stop, from})
    {:noreply, SubAgent.stop_pending_children(state)}
  end

  # A chat message (`Agent.chat/5`). The disposition is decided here,
  # in the agent process, so the status check and the enqueue cannot race:
  # this read is the authority, and the channel's own read is UX only.
  #
  # The 5-tuple arity is deliberate and there is no compatibility clause for
  # the old 2-/3-/4-tuple casts: an out-of-tree caller still using that shape
  # fails loudly with a `FunctionClauseError` in the agent process instead of
  # being silently dropped, which is what this project prefers for a shape it
  # no longer knows.
  #
  # `human?` says whether the content is the human's own words (the channel)
  # or a kickoff nobody typed (`agents-spawn`'s `query`). It is threaded
  # explicitly rather than inferred from the idle path, because *both* arms
  # tag the message the human's Ctrl/Cmd+Up recall list keys off.
  #
  # `:idle` starts the turn now (the requested mode applies immediately); a
  # busy status queues the message on the agent's own inbox for the next
  # turn boundary; a broken status drops it (logged — the channel's
  # `agent_status_<status>` reply only covers channel callers).
  def handle_cast({:chat, content, mode, sender, human?}, state) do
    chat_or_queue(state, content, mode, sender, human?)
  end

  defp chat_or_queue(state, content, mode, sender, human?) do
    status = Machine.status_for(state.live.machine)

    cond do
      # The space's before-starts latch is up **and the agent is idle**: an
      # environment edit is in progress, and a turn started now would run its
      # first tool calls against the values being replaced. It is *queued*, not
      # refused and not blocked — the same inbox a busy agent uses — and
      # `{:space_unlocked, _}` drains it (`drain_after_unlock/1`).
      #
      # The idle half is not decoration: the unlock only drains an idle agent, so
      # queueing for one that is busy or broken would leave the message with no
      # drainer at all. A busy agent's own turn boundary takes it (below), and a
      # broken one's drop-and-log is the answer the latch must not pre-empt.
      status == :idle and SpaceGate.held?(state.space_id) ->
        {state, _disposition} = Inbox.deliver_user_message(state, sender, content, mode, human?)
        {:noreply, state}

      status == :idle ->
        ChatPipeline.handle_chat(state, content, mode, sender, human?)

      Inbox.busy_status?(status) ->
        {state, _disposition} = Inbox.deliver_user_message(state, sender, content, mode, human?)
        {:noreply, state}

      true ->
        require Logger

        Logger.warning(
          "[agent:#{state.name}] dropping a chat message while status=#{inspect(status)}"
        )

        {:noreply, state}
    end
  end

  # The tool *names* an agent was built with, so the closures can be rebuilt
  # without re-reading the vocation. `state.tools` holds the closures themselves.
  # Construct the `:model_missing` recovery state. The
  # implementation lives in `Init.Recovery` so this module
  # stays focused on the dispatch surface.
  def build_recovery_state(attrs, model, reason) do
    Init.Recovery.build(attrs, model, reason)
  end

  # Introspection handle_calls (`:get_*` etc.) live in
  # `IntrospectionHandler`. The clauses below are the
  # message-mutation path (`:append_message`,
  # `:append_messages`); the catch-all at the bottom dispatches
  # every other tag to `IntrospectionHandler.handle/3`.

  # The canonical message-append path. The Agent is the single
  # writer of `index`: every message — user, assistant, tool
  # result, system reminder — flows through this handler. This
  # closes the dual-counter bug class (the old code had the
  # LLMRunner maintaining its own `state.message_index` counter
  # in parallel with `next_message_index`; the two drifted
  # whenever a side-channel message like a budget reminder was
  # injected, causing the reminder and the next response to
  # share an index).
  #
  # Both single and batch variants delegate to
  # `Nest.Agents.Agent.MessageAppender` so the loop-breaker
  # reset and `__append_message__/2` reuse logic lives in one
  # place. The batch variant exists for the Case 2 notice-pair
  # injectors (see `Nest.Agents.Agent.NoticePairInjector`).
  def handle_call({:append_message, message}, _from, state) do
    reply_append(MessageAppender.handle_single(state, message))
  end

  def handle_call({:append_messages, messages}, _from, state) do
    reply_append(MessageAppender.handle_batch(state, messages))
  end

  # Sub-agent: a tool worker (running in the chat turn) has hit an
  # `agents-spawn` tool call. `opts` carries `name`, `vocation` (slug),
  # `clone_context`, `query`, and `archive`. Spawn the child (fresh or
  # context-cloned), kick off its chat turn with the `query` (if any), and
  # reply synchronously with the child's name. The child's outcome goes to
  # this agent's own inbox (issue #31 §2.1), not back to the caller's pid.
  def handle_call({:spawn_agent_request, task_pid, opts}, _from, state) do
    SubAgent.handle_spawn_request(state, task_pid, opts)
  end

  # Sub-agent: a tool worker hit an `agents-archive` call. Stop +
  # mark the named agent in this space archived.
  def handle_call({:archive_agent_request, task_pid, name}, _from, state) do
    SubAgent.handle_archive_request(state, task_pid, name)
  end

  # Sub-agent: a tool worker hit an `agents-unarchive` call.
  # Restore the named archived agent in this space to the active list.
  def handle_call({:unarchive_agent_request, task_pid, name}, _from, state) do
    SubAgent.handle_unarchive_request(state, task_pid, name)
  end

  # Async agent-to-agent delivery (`agents-send`, `agents-query`, and the
  # runtime's own `:runtime` entries). The caller (a tool worker in another agent)
  # hands us a message; we either start a turn (idle), queue it (busy), or
  # refuse (broken state). `kind` is the entry's provenance and only decides
  # how it renders (a `:query` additionally owes a reply). See
  # `Nest.Agents.Agent.Inbox`.
  def handle_call({:deliver_async, sender, content, kind, mode}, _from, state) do
    Inbox.handle_delivery(state, sender, content, kind, mode)
  end

  # The runtime's own result for this agent, handed over by the process that
  # produced it — a batch coordinator enqueueing its aggregate. Unlike
  # `{:deliver_async, …}` this never refuses: the inbox cap bounds a runaway
  # *peer* producer, and the aggregate is this agent's own result, so refusing
  # it would lose the batch's whole output. See `Nest.Agents.Agent.Inbox`.
  def handle_call({:deliver_internal, sender, content, kind}, _from, state) do
    Inbox.deliver_internal(state, sender, content, kind)
  end

  # A tool worker registering interest for a non-blocking wait (issue #54).
  # The watch is stored before the watcher task starts, so a task that fires
  # immediately still finds its registration.
  def handle_call({:register_watch, ref, spec}, _from, state) do
    {:reply, :ok, Watch.register(state, ref, spec)}
  end

  # The watcher task's "the event fired" (issue #54). The caller decides: a
  # watch already satisfied by the watched agent's own delivery is skipped
  # (issue #62 requirement 1), so the caller wakes exactly once.
  def handle_call({:watch_fired, ref, content}, _from, state) do
    {state, disposition} = Watch.fired(state, ref, content)
    {:reply, {:ok, disposition}, state}
  end

  # Sub-agent: a tool worker running `agents-batch` hit a per-item
  # deadline. Stop the named child (so it stops consuming resources) and
  # drop it from the parent's bookkeeping. The worker blocks on the
  # reply, so this must always reply.
  def handle_call({:abandon_child, task_pid, name}, _from, state) do
    SubAgent.handle_abandon_child(state, task_pid, name)
  end

  # User clicked Stop. Runs entirely in the Agent process: set the
  # `cancelled` flag, move the machine to `:stopping`, kill the active
  # worker, and arm the bounded stop timer. The timer owns the single
  # terminal transition, so a dead or wedged turn can't leave the agent
  # busy. Stop must ALWAYS return the agent to idle within bounded time;
  # an already-idle (or already-stopping) agent is a no-op.
  def handle_call({:stop_chat, channel_pid}, _from, state) do
    # Fully in-process: move to `:stopping`, kill the active worker, and
    # arm the bounded stop timer (which owns the single terminal
    # transition). Idempotent when already stopping or already idle.
    {:ok, state} = Turn.settle(state, {:stop, channel_pid})
    {:reply, :ok, state}
  end

  # The space's environment changed under the tools this turn is running, so the
  # space edit cancels them: each worker stops its command and reports a tool
  # error. Not a Stop — nothing here ends the turn or gives up a reply.
  def handle_call({:cancel_tools, reason}, _from, state) do
    :ok = Turn.cancel_tools(state, reason)
    {:reply, :ok, state}
  end

  # Synchronous retry/loop-ack handlers. The Agent API exposes
  # `retry_compaction/1` and `compaction_loop_detected_ok/1` as
  # `GenServer.call/3`s (was `send/2`) so callers can wait for
  # the agent to actually process the request — the channel's
  # `:reply, :ok, socket` only makes sense after the agent has
  # handled the message.
  def handle_call(:retry_compaction, _from, state) do
    if Machine.status_for(state.live.machine) == :compaction_failed do
      {:ok, state} = Turn.settle(state, :retry_compaction)
      {:reply, :ok, state}
    else
      require Logger

      Logger.warning(
        "retry_compaction ignored: agent=#{state.name} " <>
          "status=#{inspect(Machine.status_for(state.live.machine))} (expected :compaction_failed)"
      )

      {:reply, :ok, state}
    end
  end

  # A manual `/compact [focus]`. The Agent is the single authority on
  # whether a compaction may start: only `:idle` stages one. Every other
  # status (streaming, executing_tools, compacting, blocked) replies with
  # `{:error, {:not_idle, status}}` and leaves the machine untouched, so
  # there is no TOCTOU window between a channel-side check and the stage.
  # The optional `focus` is the operator's guidance for the summary.
  def handle_call({:compact, focus}, _from, state) do
    case Machine.status_for(state.live.machine) do
      :idle ->
        {:ok, state} = Turn.settle(state, {:compact_request, focus})
        {:reply, :ok, state}

      status ->
        {:reply, {:error, {:not_idle, status}}, state}
    end
  end

  def handle_call(:compaction_loop_detected_ok, _from, state) do
    if Machine.status_for(state.live.machine) == :compaction_loop_detected do
      {:ok, state} = Turn.settle(state, :loop_ack)
      {:reply, :ok, state}
    else
      require Logger

      Logger.warning(
        "compaction_loop_detected_ok ignored: agent=#{state.name} " <>
          "status=#{inspect(Machine.status_for(state.live.machine))} " <>
          "(expected :compaction_loop_detected)"
      )

      {:reply, :ok, state}
    end
  end

  # Catch-all dispatcher for introspection calls.
  def handle_call(msg, from, state) do
    IntrospectionHandler.handle(msg, from, state)
  end

  # The tagged append result maps to the legacy GenServer reply for
  # trusted callers: the stamped message(s) on success, `:stale` for a
  # dropped stale result, and `{:error, reason}` for a broken sequence
  # (which also fails the turn cleanly so the agent is never left live on
  # an invalid tail).
  defp reply_append({:ok, stamped, state}), do: {:reply, stamped, state}
  defp reply_append({:stale, state}), do: {:reply, :stale, state}

  defp reply_append({:invalid, reason, state}) do
    {:ok, state} = Turn.settle(state, {:append_result, :invalid, reason})
    {:reply, {:error, reason}, state}
  end

  # Extract the index from a stamped message tuple. Exposed
  # so in-process callers can read back the stamped index
  # without re-doing the pattern match.
  @doc false
  def stamped_index({_role, %{index: index}}), do: index

  # Compaction completion is handled in-process by the `{:commit_done}`
  # transition (`Machine.Compaction.resume/1`), so it never arrives here.
  # The space changed while this agent was **stopped**, so nobody could cast it.
  # `init/1` sends this to itself — it may not touch the DB — and the notice is
  # appended here, from the mounts the agent just started with, which are already
  # the space's current values.
  def handle_info(:space_notice_pending, state) do
    {state, outcome} =
      WorkspaceHandler.apply_space_environment(state, WorkspaceHandler.values_from_mounts(state))

    {:noreply, maybe_clear_space_notice(state, outcome)}
  end

  # The space's latch came down. A turn that arrived while it was up is in the
  # inbox (`chat_or_queue/5`), so this is the wake-up: the drain is
  # `Turn.drain_inbox/1`, the single drain path, and not a second one. A busy agent
  # needs nothing: its next boundary drains.
  def handle_info({:space_unlocked, space_id}, state) when space_id == state.space_id do
    {:noreply, drain_after_unlock(state)}
  end

  def handle_info({:space_unlocked, _other_space}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end

  # `Turn.drain_inbox/1` rather than a peek plus a settle of our own: it is the
  # documented single drain path, and it owns the mode bookkeeping a hand-rolled
  # drain loses — it writes down a mode change it delivered (`keep_mode/2`) and
  # undoes one whose message stayed queued (`restore_undelivered_mode/3`, issue
  # #103). `Turn.notice_lost_batch/3` drains an idle agent the same way.
  defp drain_after_unlock(state) do
    if Machine.status_for(state.live.machine) == :idle do
      {state, _result} = Turn.drain_inbox(state)
      state
    else
      state
    end
  end

  # The cast carries the space's own names; the handler works in mount names.
  defp to_mounts_values(values) do
    %{
      workspace: values.workspace_path,
      network_access: values.network_access,
      backend: values.sandbox_backend
    }
  end

  # The flag means "this agent has not been told". The space edit sets it on every
  # agent before it casts (`Nest.Spaces.announce_environment/1`), and it is cleared
  # only when the notice is in the transcript.
  #
  # `:deferred` does **not** clear it here. The values are on the compaction's
  # entry at that point, and nothing in the transcript has them yet: a stop,
  # archive, crash or deploy before the commit loses the entry, and a cleared row
  # would then claim the agent had been told. The executor clears the flag when
  # `Machine.Compaction.resume/1` actually appends the pair
  # (`{:set_space_notice_pending, false}`), which is the same rule the start path
  # follows.
  #
  # Neither path may clear it on an outcome that appended nothing: the flag is
  # what makes the change survive to a start, and a mid-turn cast is exactly the
  # case where nothing could be appended. Clearing it there is how the notice was
  # lost before — the edit had excluded the agents it cast from the mark, so a
  # busy agent ended up with no transcript entry *and* no flag.
  defp maybe_clear_space_notice(state, :appended) do
    :ok = Persistence.set_space_notice_pending(state.space_id, state.name, false)
    state
  end

  defp maybe_clear_space_notice(state, :deferred), do: state

  defp maybe_clear_space_notice(state, outcome) do
    Logger.info(
      "space environment change not announced on agent #{inspect(state.name)} " <>
        "(#{inspect(outcome)}); it stays pending and is announced at the next start"
    )

    state
  end
end
