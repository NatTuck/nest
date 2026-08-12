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
  alias Nest.Agents.Agent.Compaction.ResultHandler
  alias Nest.Agents.Agent.Handlers
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.IntrospectionHandler
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SubAgent

  # Sub-agent: child finished its turn. Merge usage, drop the
  # pending-child entry, forward the result, broadcast status.
  def handle_cast({:child_completed, child_name, response, child_total_usage}, state) do
    SubAgent.handle_child_completed(state, child_name, response, child_total_usage)
  end

  # ChatTurn finished unwinding from a user-initiated stop.
  # The ChatTurn casts this from `Lifecycle.stop_chat/2`'s
  # cleanup — it doesn't wait for a reply (the Agent's
  # `chat_stopped/1` does DB I/O). Delegated to the existing
  # `ChatTurnHandler.chat_stopped/2` via `Handlers.handle/2`'s
  # `route_for/1` — but `handle_cast` doesn't go through
  # `Handlers`, so we delegate directly.
  def handle_cast({:chat_stopped, chat_turn_pid}, state) do
    Handlers.ChatTurnHandler.handle({:chat_stopped, chat_turn_pid}, state)
  end

  # Defense-in-depth: drop messages while busy. See channel layer.
  def handle_cast({:chat, content}, state), do: chat_or_drop(state, content, nil)
  def handle_cast({:chat, content, mode}, state), do: chat_or_drop(state, content, mode)

  defp chat_or_drop(state, _content, _mode)
       when state.live.status in [:streaming, :executing_tools, :model_missing],
       do: {:noreply, state}

  defp chat_or_drop(state, content, mode), do: ChatPipeline.handle_chat(state, content, mode)

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
    {stamped, state} = MessageAppender.handle_single(state, message)
    {:reply, stamped, state}
  end

  def handle_call({:append_messages, messages}, _from, state) do
    {stamped, state} = MessageAppender.handle_batch(state, messages)
    {:reply, stamped, state}
  end

  # Sub-agent: a tool worker (running in the chat turn) is
  # blocked on the tool dispatch and has hit an `agents/spawn`
  # tool call. `opts` carries `name`, `vocation_id`,
  # `clone_context`, `query`, and `archive`. Spawn the child
  # (fresh or context-cloned), kick off its chat turn with the
  # `query` (if any), remember the worker's pid so we can
  # forward the eventual `:spawn_agent_result`, and reply
  # synchronously with the child's name so the worker can match
  # its `receive` on child identity.
  def handle_call({:spawn_agent_request, task_pid, opts}, _from, state) do
    SubAgent.handle_spawn_request(state, task_pid, opts)
  end

  # Sub-agent: a tool worker hit an `agents/archive` call. Stop +
  # mark the named agent in this space archived.
  def handle_call({:archive_agent_request, task_pid, name}, _from, state) do
    SubAgent.handle_archive_request(state, task_pid, name)
  end

  # User clicked Stop. Synchronously mark the in-flight
  # ChatTurn as cancelled and tell it to do the actual stop
  # work (kill worker, ack the channel, send `:chat_stopped`
  # to ourselves, stop). The `cancelled` flag is set FIRST
  # so any concurrent `GenServer.call(:get_messages_with_cancelled)`
  # from the ChatTurn's `handle_info` clauses sees the flag
  # after this `handle_call` returns. The call to the
  # ChatTurn uses a 5s timeout to break the rare deadlock
  # where the ChatTurn is itself blocked on
  # `safe_iterate/1`'s `GenServer.call(agent, ...)` — the
  # ChatTurn's `iterate/1` catches the exit and stops cleanly.
  def handle_call({:stop_chat, channel_pid}, _from, state) do
    state = %{state | live: %{state.live | cancelled: true}}

    if chat_turn_pid = state.live.chat_turn_pid do
      try do
        GenServer.call(chat_turn_pid, {:stop_chat, channel_pid}, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:reply, :ok, state}
  end

  # Synchronous retry/loop-ack handlers. The Agent API exposes
  # `retry_compaction/1` and `compaction_loop_detected_ok/1` as
  # `GenServer.call/3`s (was `send/2`) so callers can wait for
  # the agent to actually process the request — the channel's
  # `:reply, :ok, socket` only makes sense after the agent has
  # handled the message.
  def handle_call(:retry_compaction, from, state) do
    ResultHandler.handle_call(:retry_compaction, from, state)
  end

  def handle_call(:compaction_loop_detected_ok, from, state) do
    ResultHandler.handle_call(:compaction_loop_detected_ok, from, state)
  end

  # Catch-all dispatcher for introspection calls.
  def handle_call(msg, from, state) do
    IntrospectionHandler.handle(msg, from, state)
  end

  # Extract the index from a stamped message tuple. Exposed
  # so in-process callers can read back the stamped index
  # without re-doing the pattern match.
  @doc false
  def stamped_index({_role, %{index: index}}), do: index

  # Compaction completion is handled in-process by
  # `Nest.Agents.Agent.Compaction.ResultHandler.handle_success/3`
  # (called from `Handlers.CompactionHandler.handle/2` on
  # `{:compaction_done, ...}` arrival).
  def handle_info(msg, state) do
    Handlers.handle(msg, state)
  end
end
