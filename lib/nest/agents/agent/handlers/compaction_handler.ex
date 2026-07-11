defmodule Nest.Agents.Agent.Handlers.CompactionHandler do
  @moduledoc """
  Compaction completion + retry events. Routes to
  `Nest.Agents.Agent.Compaction.ResultHandler` for the
  actual work.

  Events handled:

    * `{:compaction_done, summary_text, carried_entry}` —
      the compactor's chat turn finished successfully. The
      ResultHandler strips thinking, builds summary_user,
      archives old messages, broadcasts `chat:compaction`,
      and spawns the next chat turn.
    * `{:compaction_failed, reason, carried_entry}` — the
      compactor's chat turn failed. The ResultHandler sets
      `:compaction_failed` status, broadcasts `chat:error`.
    * `{:needs_compaction, _chat_turn_pid, carried_entry}` —
      a running ChatTurn detected overflow. The
      ResultHandler starts the compactor's chat turn.
    * `:retry_compaction` — user clicked the retry button
      on a `:compaction_failed` banner. The ResultHandler
      re-spawns the compactor.
    * `:compaction_loop_detected_ok` — user clicked the
      OK button on a loop banner. Restores `:idle` status.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Compaction.ResultHandler

  @doc """
  Dispatch a compaction message. Returns the GenServer's
  reply tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:compaction_done, summary_text, carried_entry}, state) do
    {:noreply, ResultHandler.handle_success(state, summary_text, carried_entry)}
  end

  def handle({:compaction_failed, reason, carried_entry}, state) do
    {:noreply, ResultHandler.handle_error(state, reason, carried_entry)}
  end

  def handle({:needs_compaction, _chat_turn_pid, carried_entry}, state) do
    {:noreply, ResultHandler.needs_entry(state, carried_entry)}
  end

  def handle(:retry_compaction, state) do
    {:noreply, ResultHandler.retry_compaction(state)}
  end

  def handle(:compaction_loop_detected_ok, state) do
    {:noreply, ResultHandler.loop_detected_ok(state)}
  end
end
