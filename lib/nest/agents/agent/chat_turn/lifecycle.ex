defmodule Nest.Agents.Agent.ChatTurn.Lifecycle do
  @moduledoc """
  End-of-turn / cleanup helpers for the ChatTurn. Extracted
  from `Nest.Agents.Agent.ChatTurn` to keep the iteration
  state machine under the credo line and complexity limits.

  Owns three concerns:

    * `stop_chat/2` — user clicked Stop. Reply `:stopped`
      to the channel, give the active worker a chance to
      clean up in-flight OS subprocesses (`{:stop_chat, _}`
      message), kill the worker as a failsafe, notify
      the Agent via `GenServer.cast`, and stop the
      ChatTurn. Returns `{:stop, :normal, :ok, state}` so the
      ChatTurn's `handle_call({:stop_chat, _}, _, _)` acks the
      caller and actually terminates.
    * `worker_exited/3` — a worker died. `:normal` means the
      result was already delivered; `:shutdown` / `:killed`
      mean the worker stopped without delivering a result, so
      the chat is finalized as stopped (quietly idle) rather
      than hang. Other reasons become a `{:chat_crashed, _, _}`
      to the Agent.
    * `finalize_turn/1` — end-of-turn. Send `:chat_idle` and
      `:api_log_sequences_updated` to the Agent, then stop.

  Each function returns a valid GenServer callback tuple
  (`{:noreply, state}`, `{:stop, :normal, state}`, or the
  `handle_call` stop-with-reply `{:stop, :normal, :ok, state}`)
  so the ChatTurn's `handle_info/2` and `handle_call/3` clauses
  can return them directly.
  """

  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.Messages.MessageList

  require Logger

  @doc """
  Read the Agent's `cancelled` flag. 100ms timeout prevents deadlock if
  the Agent is itself blocked (e.g. on the `GenServer.call({:stop_chat,
  _})` chain). On timeout, defaults to `false`; `safe_iterate/1` makes
  the same call without a timeout on the next iteration, so the flag is
  eventually observed.
  """
  @spec cancelled?(State.t()) :: boolean()
  def cancelled?(state) do
    {_messages, cancelled} =
      GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled, 100)

    cancelled
  catch
    :exit, _ -> false
  end

  @doc """
  User clicked Stop. Ack the channel with `:stopped`, give the
  active worker a chance to clean up in-flight
  subprocesses (e.g. `:erlexec` bwrap OS processes that the
  BEAM kill alone doesn't reliably reach — bwrap's PID
  namespace isolation can leave the inner command running
  for up to `{:kill_timeout, 5000}`ms in the best case and
  indefinitely in the worst case), kill the worker as a
  failsafe, notify the Agent via `GenServer.cast`, and stop
  the ChatTurn. Returns `{:stop, :normal, :ok, state}` — the
  gen_server `handle_call` stop-with-reply shape, so the
  caller's `GenServer.call/3` gets `:ok` AND the ChatTurn
  actually terminates (a nested `{:reply, :ok, {:stop, ...}}`
  is not a valid callback return: gen_server would treat the
  nested tuple as the new state and the turn would leak).
  """
  @spec stop_chat(pid(), State.t()) ::
          {:stop, :normal, :ok, State.t()}
  def stop_chat(channel_pid, state) do
    send(channel_pid, :stopped)

    if state.active_worker do
      # BEAM FIFO delivery guarantees this `{:stop_chat, _}`
      # message is processed before the `Process.exit(..., :kill)`
      # below (if the worker is in BEAM code). Stop-aware tools
      # (e.g. `ShellCmd.collect_output/3`'s `{:stop_chat, _}`
      # clause) use this hook to call `:exec.stop(os_pid, 9)`
      # and exit cleanly. The kill is the failsafe for tools
      # that don't have a stop clause (e.g. stuck in a NIF).
      send(state.active_worker, {:stop_chat, self()})
      Process.exit(state.active_worker, :kill)
    end

    state = %{
      state
      | active_worker: nil,
        active_worker_kind: nil
    }

    # Fire-and-forget to the Agent — `cast` is the SMELLS.md
    # compliant choice for GenServer-to-GenServer notifications
    # where the sender doesn't wait for a reply. The Agent's
    # `chat_stopped/1` handler is idempotent (no-op on
    # `:idle`).
    GenServer.cast(state.ctx.agent_pid, {:chat_stopped, self()})

    {:stop, :normal, :ok, state}
  end

  @doc """
  A worker died.

  A tool worker that dies without delivering a result leaves the tail on
  an unanswered assistant `tool_use`. If the turn was not cancelled, the
  recovery is to answer the call with the canonical `is_error` result and
  **continue** the turn (the model sees the error and can react) rather
  than idling on a broken sequence. A cancelled turn (user Stop) still
  ends: the Agent's stop path appends the placeholder and the append-time
  bridge answers the call durably.

  Everything else keeps the old behavior: `:normal` means the result was
  already delivered so we just clear the slot; `:shutdown`/`:killed`
  without a pending tool call finalize quietly; any other reason becomes
  a `{:chat_crashed, _, _}` to the Agent.
  """
  @spec worker_exited(pid(), term(), State.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def worker_exited(_pid, reason, state) do
    tool_uses =
      if state.active_worker_kind == :tools do
        pending_tool_uses(state)
      else
        []
      end

    cond do
      tool_uses != [] and not cancelled?(state) ->
        recover_interrupted_tool(state, tool_uses)

      reason == :normal ->
        clear_worker(state)

      reason in [:shutdown, :killed] or match?({:shutdown, _}, reason) ->
        finalize_stopped_turn(state)

      true ->
        send(state.ctx.agent_pid, {:chat_crashed, reason, []})
        {:stop, :normal, state}
    end
  end

  # Quietly tell the Agent the turn is over so it leaves its busy
  # status, then stop the ChatTurn.
  defp finalize_stopped_turn(state) do
    GenServer.cast(state.ctx.agent_pid, {:chat_stopped, self()})
    {:stop, :normal, state}
  end

  defp clear_worker(state),
    do: {:noreply, %{state | active_worker: nil, active_worker_kind: nil}}

  # The unanswered `tool_use`s on the Agent's trailing assistant message,
  # or `[]` when the turn's tool worker already delivered (or there is no
  # pending call). Read from the Agent because the ChatTurn does not keep
  # the response message in its own state.
  defp pending_tool_uses(state) do
    messages =
      try do
        GenServer.call(state.ctx.agent_pid, :get_messages, 1_000)
      catch
        :exit, _ -> []
      end

    MessageList.unpaired_tail_tool_uses(messages)
  end

  # Answer the interrupted tool call with an error result and iterate, so
  # the model can decide what to do (retry, try something else, or give
  # up). The append goes through the canonical path (persisted, broadcast,
  # visible); the bridge no-ops because the incoming result answers every
  # pending id.
  defp recover_interrupted_tool(state, tool_uses) do
    state = %{state | active_worker: nil, active_worker_kind: nil}

    case MessageList.interrupted_tool_result(tool_uses) do
      nil ->
        finalize_stopped_turn(state)

      tool_msg ->
        Logger.warning(
          "Chat turn for agent #{state.ctx.agent_name} lost its tool worker without a result; " <>
            "answering #{length(tool_uses)} tool_use id(s) with an error result and continuing."
        )

        GenServer.call(state.ctx.agent_pid, {:append_message, tool_msg})
        Process.send(self(), :iterate, [])
        {:noreply, state}
    end
  end

  @doc """
  End of turn. Send `:chat_idle` and
  `:api_log_sequences_updated` to the Agent, then stop.
  Returns `{:stop, :normal, state}`.
  """
  @spec finalize_turn(State.t()) :: {:stop, :normal, State.t()}
  def finalize_turn(state) do
    send(state.ctx.agent_pid, {:chat_idle, self()})
    send(state.ctx.agent_pid, {:api_log_sequences_updated, APILog.read_sequences()})
    {:stop, :normal, state}
  end

  @doc """
  End of the compactor's own chat turn. Send
  `{:compaction_done, summary_text, carried_entry}` to
  the Agent, then stop. The Agent's
  `Compaction.ResultHandler` takes over from here — it
  strips thinking, builds summary_user, archives old
  messages, and broadcasts the new active message list.

  `carried_entry` is the third element of the
  `{:compaction, staged, carried_entry}` entry — `nil` for
  Trigger A (post-turn) or the carried
  `{:tool_call, _, _, _}` / `{:compact_tool, _, _, _}` for
  Trigger B (mid-turn). The carried entry is what
  `Compaction.ResultHandler` uses to spawn the next
  ChatTurn (the tool call sequence resumes).

  `staged` (the second element) is the staged compaction request — an
  assistant bridge when needed plus the `[mode: compact]` suffix — and
  `summary_assistant` is the summary as a `{:assistant, Assistant.t()}`
  tuple. Neither is persisted yet; `ResultHandler` writes them only when the
  compaction commits.

  Returns `{:stop, :normal, state}`.
  """
  @spec finalize_compaction(State.t(), Nest.LLM.RunResponse.t(), tuple()) ::
          {:stop, :normal, State.t()}
  def finalize_compaction(state, response, summary_assistant) do
    {_, staged, carried_entry} = state.entry

    send(
      state.ctx.agent_pid,
      {:compaction_done, response.text || "", staged, summary_assistant, carried_entry}
    )

    send(state.ctx.agent_pid, {:api_log_sequences_updated, APILog.read_sequences()})
    {:stop, :normal, state}
  end
end
