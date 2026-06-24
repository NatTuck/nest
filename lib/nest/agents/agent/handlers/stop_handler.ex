defmodule Nest.Agents.Agent.Handlers.StopHandler do
  @moduledoc """
  `handle_info/2` handlers for the user-initiated chat stop flow.

  After the ChatTurn refactor, the stop handler is a thin
  forwarder. The user clicks Stop in the channel; the
  channel pushes `chat:stop` to the Agent. The Agent's
  stop handler sends `{:stop_chat, from}` to the
  in-flight ChatTurn's mailbox (no work done here on the
  Agent's side beyond setting the `cancelled` flag). The
  ChatTurn kills the active HTTP worker, sends
  `{:chat_stopped, self()}` back to the Agent, and the
  Agent's `LLMStreamHandler.chat_stopped/1` does the
  partial finalization and the `:idle` transition.

  The `:chat_stopped` clause here is a no-op shim kept
  so the dispatch in `Nest.Agents.Agent.Handlers` has
  somewhere to route the message (it actually gets
  handled by the `LLMStreamHandler` via the same
  dispatch).
  """

  @doc """
  Dispatch a stop-flow message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:stop_chat, from}, state) do
    stop_chat_requested(from, state)
  end

  def handle({:chat_stopped, _chat_turn_pid}, state) do
    # The ChatTurn's stop handler does the actual partial
    # finalization and the `:idle` transition. This clause
    # is a no-op shim kept for backward compat — the real
    # `chat_stopped/1` work is in
    # `LLMStreamHandler.chat_stopped/1`. The Handlers
    # dispatcher routes `{:chat_stopped, _}` to the
    # LLMStreamHandler first, so this clause is only
    # reached for stale messages.
    {:noreply, state}
  end

  # The channel pushed `chat:stop`. Signal the in-flight
  # ChatTurn (if any) to halt. The ChatTurn replies
  # `:stopped` to the channel's push and unwinds the
  # iteration; we set the `cancelled` flag and reply
  # synchronously so the channel's `chat:stop` push
  # unblocks.
  #
  # The reply to the channel is `:ok` (the channel's
  # `handle_in("chat:stop", ...)` only sees the
  # `{:ok, %{}}` we already returned synchronously; the
  # `handle_info` reply goes to the channel pid via
  # `send/2` but the channel doesn't block on it).
  defp stop_chat_requested(_from, state) do
    state =
      case state.chat_state.chat_turn_pid do
        nil ->
          # No ChatTurn in flight; the stop is a no-op.
          # Still set the cancelled flag so any in-flight
          # compaction continuation does not auto-resume.
          %{state | chat_state: %{state.chat_state | cancelled: true}}

        chat_turn_pid when is_pid(chat_turn_pid) ->
          # `Process.send/3` is `:noconnect` and a no-op
          # if the pid is no longer alive, so a click
          # after the ChatTurn has already completed is
          # safe. The ChatTurn replies `:stopped` to
          # `self()` and sends `{:chat_stopped, self()}`
          # back to the Agent to trigger the
          # `chat_stopped` handler (which finalizes the
          # partial and transitions to :idle).
          send(chat_turn_pid, {:stop_chat, self()})

          %{
            state
            | chat_state: %{state.chat_state | cancelled: true}
          }
      end

    {:noreply, state}
  end
end
