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

  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.IntrospectionHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Agent.Turn

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

  # A human chat message (`Agent.chat/4`). The disposition is decided here,
  # in the agent process, so the status check and the enqueue cannot race:
  # this read is the authority, and the channel's own read is UX only.
  #
  # The 4-tuple arity is deliberate and there is no compatibility clause for
  # the old 2-/3-tuple casts: an out-of-tree caller still using that shape
  # fails loudly with a `FunctionClauseError` in the agent process instead of
  # being silently dropped, which is what this project prefers for a shape it
  # no longer knows.
  # `:idle` starts the turn now (the requested mode applies immediately); a
  # busy status queues the message on the agent's own inbox for the next
  # turn boundary; a broken status drops it (logged — the channel's
  # `agent_status_<status>` reply only covers channel callers).
  def handle_cast({:chat, content, mode, sender}, state) do
    chat_or_queue(state, content, mode, sender)
  end

  defp chat_or_queue(state, content, mode, sender) do
    status = Machine.status_for(state.live.machine)

    cond do
      status == :idle ->
        ChatPipeline.handle_chat(state, content, mode)

      Inbox.busy_status?(status) ->
        {:noreply, Inbox.enqueue_user_message(state, sender, content, mode)}

      true ->
        require Logger

        Logger.warning(
          "[agent:#{state.name}] dropping a chat message while status=#{inspect(status)}"
        )

        {:noreply, state}
    end
  end

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
  # context-cloned), kick off its chat turn with the `query` (if any),
  # remember the caller's pid — the blocking worker, or the async waiter
  # it started — so we can forward the eventual `:spawn_agent_result`,
  # and reply synchronously with the child's name so the caller can match
  # its `receive` on child identity.
  def handle_call({:spawn_agent_request, task_pid, opts}, _from, state) do
    SubAgent.handle_spawn_request(state, task_pid, opts)
  end

  # Sub-agent: a tool worker hit an `agents-archive` call. Stop +
  # mark the named agent in this space archived.
  def handle_call({:archive_agent_request, task_pid, name}, _from, state) do
    SubAgent.handle_archive_request(state, task_pid, name)
  end

  # Async agent-to-agent delivery (`agents-send`). The caller (a tool
  # worker in another agent) hands us a message; we either start a turn
  # (idle), queue it (busy), or refuse (broken state). See
  # `Nest.Agents.Agent.Inbox`.
  def handle_call({:deliver_async, sender, content}, _from, state) do
    Inbox.handle_delivery(state, sender, content)
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
  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end
end
