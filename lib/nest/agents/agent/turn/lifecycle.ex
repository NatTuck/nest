defmodule Nest.Agents.Agent.Turn.Lifecycle do
  @moduledoc """
  End-of-turn / cleanup helpers for the in-process turn driver.

  Owns three concerns:

    * `stop/2` — the user clicked Stop. Ack the channel, move the machine
      to `:stopping`, give the active worker a chance to clean up
      in-flight OS subprocesses, kill it as a failsafe, and arm the
      bounded `:stop_timer`. The timer owns the single terminal
      transition to idle (see `Nest.Agents.Agent.Turn`).
    * `worker_exited/3` — a worker died without delivering a result.
    * `finalize_turn/1` / `finalize_compaction/3` — terminal transitions.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Handlers.TurnHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.Repair
  alias Nest.Messages.MessageList

  require Logger

  @doc """
  The Agent's sticky `cancelled` flag.
  """
  @spec cancelled?(Agent.t()) :: boolean()
  def cancelled?(state), do: state.live.cancelled

  @doc """
  The user clicked Stop. Runs entirely in the Agent process: ack the
  channel with `:stopped`, move the machine into the `:stopping` phase,
  kill the active worker (after a stop-aware cleanup hook), and arm the
  bounded `:stop_timer`. The timer, not this call, performs the single
  terminal transition to idle. A stop while already `:stopping` (a
  second click, or a stop racing a late result) is a no-op; a stop on an
  already-idle agent is a no-op. Returns the updated state.
  """
  @spec stop(Agent.t(), pid()) :: Agent.t()
  def stop(state, channel_pid) do
    machine = state.live.machine

    cond do
      Machine.stopping?(machine) -> state
      Machine.status_for(machine) == :idle -> state
      true -> begin_stop(state, channel_pid)
    end
  end

  defp begin_stop(state, channel_pid) do
    send(channel_pid, :stopped)
    state = %{state | live: %{state.live | cancelled: true}}
    state = kill_active_worker(state)

    ref = Process.send_after(self(), :stop_timer, Config.configured_stop_fallback_ms())
    machine = %{Machine.to_stopping(state.live.machine) | stop_timer: ref}
    %{state | live: %{state.live | machine: machine}}
  end

  defp kill_active_worker(state) do
    case state.live.machine.work.active_worker do
      nil ->
        state

      pid ->
        # BEAM FIFO delivery guarantees this `{:stop_chat, _}` is processed
        # before the `Process.exit(..., :kill)` when the worker is in BEAM
        # code, so stop-aware tools can unwind their OS subprocesses.
        send(pid, {:stop_chat, self()})
        Process.exit(pid, :kill)
        state
    end
  end

  @doc """
  A worker died. A tool worker that dies without delivering a result
  leaves the tail on an unanswered assistant `tool_use`; recovery is to
  answer the call with the canonical `is_error` result and continue.
  Everything else keeps the old semantics.
  """
  @spec worker_exited(pid(), term(), Agent.t()) :: {:noreply, Agent.t()}
  def worker_exited(_pid, reason, state) do
    if Machine.stopping?(state.live.machine) do
      # The stop timer owns the single terminal transition. A DOWN for
      # the worker we just killed must not finalize the turn first.
      {:noreply, state}
    else
      worker_exited_body(reason, state)
    end
  end

  defp worker_exited_body(reason, state) do
    tool_uses =
      if state.live.machine.work.active_worker_kind == :tools do
        MessageList.unpaired_tail_tool_uses(state.chat_state.messages)
      else
        []
      end

    cond do
      tool_uses != [] and not cancelled?(state) ->
        recover_interrupted_tool(state, tool_uses)

      reason == :normal ->
        {:noreply, clear_worker(state)}

      reason in [:shutdown, :killed] or match?({:shutdown, _}, reason) ->
        {:noreply, TurnHandler.chat_stopped_state(state)}

      true ->
        {:noreply, TurnHandler.chat_crashed_state(reason, [], state)}
    end
  end

  defp clear_worker(state) do
    update_work(state, &%{&1 | active_worker: nil, active_worker_kind: nil, worker_ref: nil})
  end

  defp recover_interrupted_tool(state, tool_uses) do
    state = clear_worker(state)

    case Repair.decide(:worker_death, state.chat_state.messages, nil) do
      :none ->
        {:noreply, TurnHandler.chat_stopped_state(state)}

      {:repair, [tool_msg]} ->
        Logger.warning(
          "Chat turn for agent #{state.name} lost its tool worker without a result; " <>
            "answering #{length(tool_uses)} tool_use id(s) with an error result and continuing."
        )

        append_recovery(state, tool_msg)
    end
  end

  # The repair result answers the unanswered tail `tool_use`, so the live
  # append is valid (`:ok`).
  defp append_recovery(state, tool_msg) do
    {:ok, _stamped, state} = MessageAppender.handle_single(state, tool_msg)
    send(self(), :iterate)
    {:noreply, state}
  end

  @doc """
  End of an ordinary turn. Clears the turn and transitions to idle
  (notifying the parent and draining the inbox).
  """
  @spec finalize_turn(Agent.t()) :: {:noreply, Agent.t()}
  def finalize_turn(state) do
    {:noreply, state |> clear_turn() |> TurnHandler.chat_idle_state()}
  end

  @doc """
  End of the compactor's own turn. Emits `{:compaction_done, ...}` back
  to the Agent and clears the turn. `Compaction.ResultHandler` takes over
  on the next message.
  """
  @spec finalize_compaction(Agent.t(), Nest.LLM.RunResponse.t(), tuple()) ::
          {:noreply, Agent.t()}
  def finalize_compaction(state, response, summary_assistant) do
    {_, staged, carried_entry} = state.live.machine.entry

    send(
      self(),
      {:compaction_done, response.text || "", staged, summary_assistant, carried_entry}
    )

    {:noreply, clear_turn(state)}
  end

  @doc """
  Reset the turn-scoped working memory (work + entry) to its default,
  preserving the machine's resume intents and the loop-breaker counter.
  """
  @spec clear_turn(Agent.t()) :: Agent.t()
  def clear_turn(state) do
    machine = state.live.machine

    %{
      state
      | live: %{
          state.live
          | machine: %{machine | work: %Nest.Agents.Agent.Machine.Work{}, entry: nil}
        }
    }
  end

  defp update_work(state, fun) do
    machine = state.live.machine
    %{state | live: %{state.live | machine: %{machine | work: fun.(machine.work)}}}
  end
end
