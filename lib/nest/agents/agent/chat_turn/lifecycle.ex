defmodule Nest.Agents.Agent.ChatTurn.Lifecycle do
  @moduledoc """
  End-of-turn / cleanup helpers for the ChatTurn. Extracted
  from `Nest.Agents.Agent.ChatTurn` to keep the iteration
  state machine under the credo line and complexity limits.

  Owns four concerns:

    * `stop_chat/2` — user clicked Stop. Reply `:stopped`,
      kill the active worker, notify the Agent, stop the
      ChatTurn.
    * `drain_stop_message/0` — non-blocking mailbox check for
      a pending `{:stop_chat, _}` message. Used by
      `handle_info({:http_response, _}, state)` to honor a
      stop that arrived before the response was processed.
    * `worker_exited/3` — a worker died. `:normal` and
      `:killed` are expected exits; other reasons become a
      `{:chat_crashed, _, _}` to the Agent.
    * `finalize_turn/1` — end-of-turn. Send `:chat_idle` and
      `:api_log_sequences_updated` to the Agent, then stop.

  Each function returns the GenServer reply tuple
  (`{:noreply, state}` or `{:stop, :normal, state}`) so the
  ChatTurn's `handle_info/2` clauses can return them
  directly.
  """

  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.State

  @doc """
  User clicked Stop. Reply `:stopped`, kill the active
  worker, notify the Agent, and stop the ChatTurn. Returns
  `{:stop, :normal, state}`.
  """
  @spec stop_chat(pid(), State.t()) :: {:stop, :normal, State.t()}
  def stop_chat(from, state) do
    send(from, :stopped)

    if state.active_worker do
      Process.exit(state.active_worker, :kill)
    end

    state = %{state | active_worker: nil, active_worker_kind: nil}
    send(state.ctx.agent_pid, {:chat_stopped, self()})
    {:stop, :normal, state}
  end

  @doc """
  Non-blocking mailbox check for `{:stop_chat, _}`. Returns
  `{:stop, from}` if a stop is pending, otherwise `nil`.

  Used by `handle_info({:http_response, _}, state)` to honor
  a stop that arrived in the mailbox between the worker's
  last event and its final `{:http_response, _}` message
  (the racy case where the worker finishes its stream in
  microseconds — MockClient yields events instantly — and
  the stop arrives after).
  """
  @spec drain_stop_message() :: {:stop, pid()} | nil
  def drain_stop_message do
    receive do
      {:stop_chat, from} -> {:stop, from}
    after
      0 -> nil
    end
  end

  @doc """
  A worker died. `:normal` and `:killed` are expected exits
  (the stop handler killed the worker, or the tool worker
  completed normally). Other reasons are crashes and become
  a `{:chat_crashed, reason, []}` to the Agent.
  """
  @spec worker_exited(pid(), term(), State.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def worker_exited(_pid, :normal, state), do: {:noreply, state}
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
end
