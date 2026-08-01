defmodule Nest.Agents.Agent.ChatTurn.Lifecycle do
  @moduledoc """
  End-of-turn / cleanup helpers for the ChatTurn. Extracted
  from `Nest.Agents.Agent.ChatTurn` to keep the iteration
  state machine under the credo line and complexity limits.

  Owns three concerns:

    * `stop_chat/2` — user clicked Stop. Reply `:stopped`
      to the channel, give the active worker a chance to
      clean up in-flight OS subprocesses (`{:stop_chat, _}`
      message), kill the worker as a failsafe, notify the
      Agent via `GenServer.cast`, and stop the ChatTurn.
      Returns `{:reply, :ok, {:stop, :normal, state}}` so the
      ChatTurn's `handle_call({:stop_chat, _}, _, _)` can
      propagate it.
    * `worker_exited/3` — a worker died. `:normal` and
      `:killed` are expected exits; the `:killed` case
      after `stop_requested: true` (the failsafe kill fired
      because the worker didn't process `{:stop_chat, _}` in
      time) finalizes the chat as stopped so the Agent
      doesn't hang. Other reasons become a `{:chat_crashed,
      _, _}` to the Agent.
    * `finalize_turn/1` — end-of-turn. Send `:chat_idle` and
      `:api_log_sequences_updated` to the Agent, then stop.

  Each function returns the GenServer reply tuple
  (`{:noreply, state}` or `{:stop, :normal, state}` or
  `{:reply, value, {:stop, :normal, state}}`) so the
  ChatTurn's `handle_info/2` and `handle_call/3` clauses
  can return them directly.
  """

  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.State

  @doc """
  User clicked Stop. Ack the channel with `:stopped`, give
  the active worker a chance to clean up in-flight
  subprocesses (e.g. `:erlexec` bwrap OS processes that the
  BEAM kill alone doesn't reliably reach — bwrap's PID
  namespace isolation can leave the inner command running
  for up to `{:kill_timeout, 5000}`ms in the best case and
  indefinitely in the worst case), kill the worker as a
  failsafe, notify the Agent via `GenServer.cast`, and stop
  the ChatTurn. Returns `{:reply, :ok, {:stop, :normal,
  state}}` so the ChatTurn's `handle_call({:stop_chat, _},
  _, _)` can return it.
  """
  @spec stop_chat(pid(), State.t()) ::
          {:reply, :ok, {:stop, :normal, State.t()}}
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
        active_worker_kind: nil,
        stop_requested: true
    }

    # Fire-and-forget to the Agent — `cast` is the SMELLS.md
    # compliant choice for GenServer-to-GenServer notifications
    # where the sender doesn't wait for a reply. The Agent's
    # `chat_stopped/1` handler is idempotent (no-op on
    # `:idle`).
    GenServer.cast(state.ctx.agent_pid, {:chat_stopped, self()})

    {:reply, :ok, {:stop, :normal, state}}
  end

  @doc """
  A worker died. `:normal` and `:killed` are expected exits
  (the stop handler killed the worker, or the tool worker
  completed normally). When `stop_requested: true` and the
  reason is `:killed`, the failsafe kill fired because the
  worker didn't process `{:stop_chat, _}` in time — finalize
  the chat as stopped so the Agent doesn't hang waiting for
  a `{:tool_results, _}` that will never arrive. Other
  reasons are crashes and become a `{:chat_crashed, reason,
  []}` to the Agent.
  """
  @spec worker_exited(pid(), term(), State.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def worker_exited(_pid, :normal, state), do: {:noreply, state}

  def worker_exited(_pid, :killed, %{stop_requested: true} = state) do
    GenServer.cast(state.ctx.agent_pid, {:chat_stopped, self()})
    {:stop, :normal, state}
  end

  def worker_exited(_pid, :killed, state), do: {:noreply, state}

  def worker_exited(_pid, reason, state) do
    send(state.ctx.agent_pid, {:chat_crashed, reason, []})
    {:stop, :normal, state}
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
  `{:compaction, _, carried_entry}` entry — `nil` for
  Trigger A (post-turn) or the carried
  `{:tool_call, _, _, _}` / `{:compact_tool, _, _, _}` for
  Trigger B (mid-turn). The carried entry is what
  `Compaction.ResultHandler` uses to spawn the next
  ChatTurn (the tool call sequence resumes).

  Returns `{:stop, :normal, state}`.
  """
  @spec finalize_compaction(State.t(), Nest.LLM.RunResponse.t()) :: {:stop, :normal, State.t()}
  def finalize_compaction(state, response) do
    # The entry is `{:compaction, _system_msg, carried_entry}`.
    # The system message was for the LLM (the suffix); the
    # third element is the carried entry to thread into
    # the post-compaction ChatTurn spawn.
    {_, _system_msg, carried_entry} = state.entry

    send(
      state.ctx.agent_pid,
      {:compaction_done, response.text || "", carried_entry}
    )

    send(state.ctx.agent_pid, {:api_log_sequences_updated, APILog.read_sequences()})
    {:stop, :normal, state}
  end
end
