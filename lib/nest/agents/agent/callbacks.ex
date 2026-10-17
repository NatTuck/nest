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

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.IntrospectionHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.ModeAuthority
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Watch
  alias Nest.Messages.{Assistant, NoticeTag, Part, User}
  alias Nest.Sandbox.Mounts

  # The space's network access changed (`Nest.Spaces.set_network_access/2`).
  #
  # Two things move together and must not drift: the mounts (and the tool closures
  # built from them) and the agent's *knowledge* of the change. The system prompt's
  # network sentence was composed from the value the agent started with and is
  # deliberately never rebuilt — changing it would break the prefix cache — so a
  # `[Nest notice]` in the transcript is the only thing that makes the change
  # visible to the model. It is a message, not a system-message edit.
  #
  # Nothing is refused and nothing waits: the value is the space's. The notice is
  # *queued*, not appended, and this is the one judgement call in the change:
  # `Turn.drain_inbox/1` would append it immediately, but draining starts a turn,
  # and a turn is an LLM call — a space-wide toggle would cost one per live agent,
  # which is not a cost a checkbox should have. Queued is also what a peer's mode
  # notice does (`Turn.keep_mode/3` → `Inbox.enqueue_internal/4`), so the agent
  # learns it at the start of its next turn, which is when it can act on it.
  # A turn in flight re-reads the mounts at its next settle.
  def handle_cast({:set_network_access, value}, state) do
    state = apply_network_access(state, value)

    {:noreply,
     Inbox.enqueue_internal(
       state,
       nil,
       network_notice(value, Mounts.backend(state.mounts)),
       :notice
     )}
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
      status == :idle ->
        ChatPipeline.handle_chat(state, content, mode, human?)

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

  # Move the agent onto the space's new network access. The mounts are what carry
  # it (`Nest.Sandbox.Mounts.network_access/1`), and the tool closures capture
  # them — `Nest.Agents.Agent.Tools.get_functions/2` is the one builder — so both
  # have to move together. Nothing else in the mounts changed, which is why this
  # is a two-field update rather than a re-resolve.
  defp apply_network_access(state, value) do
    mounts = %{state.mounts | network_access: value}

    %{state | mounts: mounts, tools: Nest.Tools.get_functions(tool_names(state), mounts)}
  end

  # What the agent is told when the space's network access changes. One sentence,
  # in one place: the prompt's own sentence is the value the agent started with
  # (`SystemPrompt.network_sentence/2`, never rebuilt while a conversation is
  # live), so this is the only thing that makes a change visible. The
  # `[mode: notice]` prefix and `NoticeTag` are the shape `ModeAuthority.notice/2`
  # and `WorkspaceHandler.notice_pair/1` already use, so every runtime notice is
  # built alike.
  defp network_notice(false, "none") do
    "[mode: notice]\n" <>
      NoticeTag.tag(
        "Network access for this space is now disabled, but this space has no " <>
          "sandbox to enforce it: your commands can reach the network either way."
      )
  end

  defp network_notice(true, _backend) do
    "[mode: notice]\n" <>
      NoticeTag.tag(
        "Network access for this space is now enabled: your commands can reach the " <>
          "network."
      )
  end

  defp network_notice(false, _backend) do
    "[mode: notice]\n" <>
      NoticeTag.tag(
        "Network access for this space is now disabled: the sandbox blocks your " <>
          "commands from reaching the network."
      )
  end

  # The tool *names* an agent was built with, so the closures can be rebuilt
  # without re-reading the vocation. `state.tools` holds the closures themselves.
  defp tool_names(%{tools: tools}), do: Enum.map(tools, & &1.name)

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
  # runtime's own `:notice`). The caller (a tool worker in another agent)
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

  # The `agents-last-message` fetch (issue #62): take the newest pending
  # delivery from `name`, mark it retrieved, and publish the change. The caller
  # then cannot be delivered the same body again at its next turn boundary.
  # `mark_retrieved/2` owns both halves — the queue write and the delta that
  # describes it (issue #27) — because only the state after the write knows the
  # entry's new serialized form.
  def handle_call({:last_message, name}, _from, state) do
    case Inbox.mark_retrieved(state, name) do
      {state, nil} ->
        {:reply, :none, state}

      {state, entry} ->
        {:reply, {:ok, entry.content, entry.id}, state}
    end
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

  # A mode change on the human's behalf (the UI selector). A *busy* agent is
  # refused rather than changed: `Turn.build_ctx/2` reads `state.live.mode` on
  # every settle, so applying it now would re-resolve the caps of the *ongoing*
  # turn's remaining tool calls, and a change that lands mid-turn is exactly what
  # the rule forbids. An idle agent takes it now — the mode is persisted, so a
  # human's change does not have to ride a message — and a busy one the user can
  # retry, which is what the channel's error says.
  #
  # Validate → persist → mutate → announce, the shape a workspace change has
  # (`WorkspaceHandler.perform_workspace_change/2`) and for the same reasons. The
  # announcement is a user/assistant notice pair, like a workspace change's: the
  # user row is the runtime speaking and carries the notice marker, the assistant
  # row is the acknowledgement, and neither is an LLM request.
  def handle_call({:set_mode, mode}, _from, state) do
    if Inbox.busy_status?(Machine.status_for(state.live.machine)) do
      {:reply, {:error, busy_sentence()}, state}
    else
      change_mode(state, mode)
    end
  end

  # Catch-all dispatcher for introspection calls.
  def handle_call(msg, from, state) do
    IntrospectionHandler.handle(msg, from, state)
  end

  # The change itself, for an agent that can take one now: validate → persist →
  # mutate → announce. Split out of the `handle_call` clause above because that
  # clause's own `if` already spends one level of nesting on "can this agent take
  # a change at all". It lives after the dispatcher clause so the `handle_call/3`
  # clauses stay grouped.
  defp change_mode(state, mode) do
    with :ok <- ModeAuthority.authorize(%{kind: :human}, mode),
         :ok <- Nest.Persistence.update_agent_mode(state.space_id, state.name, mode) do
      state = %{state | live: %{state.live | mode: mode}}

      # `currentMode` only rides `chat:status`, and the settle loop broadcasts
      # only on a status *change* — which this is not — so a second client
      # watching this agent would keep the old badge until the next frame. The
      # selector path publishes it here or it is published by accident.
      Broadcasts.status(state)

      announce_mode_change(state, mode)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The notice pair is the runtime's own, appended in-process, so the tagged
  # result is the shape every in-process append returns
  # (`MessageAppender.append_in_process/2`).
  #
  # The row is already written and `live.mode` already moved by the time this
  # runs, so **the change has happened whatever this returns**. Reporting an
  # error here would tell the user the change failed when it took effect; a
  # notice that could not be appended is a change with a missing announcement,
  # and that is what it says.
  defp announce_mode_change(state, mode) do
    case MessageAppender.handle_batch(state, mode_notice_pair(mode, :human)) do
      {:ok, _stamped, state} ->
        {:reply, :ok, state}

      {:stale, state} ->
        Logger.warning(
          "mode change to #{inspect(mode)} on #{state.space_id}/#{state.name} applied, " <>
            "but its notice could not be appended: the tail moved under it"
        )

        {:reply, :ok, state}

      {:invalid, reason, state} ->
        Logger.warning(
          "mode change to #{inspect(mode)} on #{state.space_id}/#{state.name} applied, " <>
            "but its notice was rejected: #{inspect(reason)}"
        )

        {:reply, :ok, state}
    end
  end

  # A sentence the client can show, not the atom `:agent_busy`: the channel hands
  # this straight to the user.
  defp busy_sentence do
    "The agent is mid-turn. A mode applies at the start of a turn, so try again " <>
      "when it is idle."
  end

  # The notice pair a mode change appends: the runtime speaking for itself (the
  # user row carries the notice marker) and its acknowledgement. Neither is an
  # LLM request.
  defp mode_notice_pair(mode, actor) do
    [
      {:user,
       %User{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: ModeAuthority.notice(mode, actor)}],
         metadata: %{"mode" => "notice"},
         api_logs: []
       }},
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: "Mode change confirmed."}],
         api_logs: []
       }}
    ]
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
  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end
end
