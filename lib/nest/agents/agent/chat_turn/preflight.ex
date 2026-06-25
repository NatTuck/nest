defmodule Nest.Agents.Agent.ChatTurn.Preflight do
  @moduledoc """
  Asks the Agent to run a pre-flight compaction check before
  this LLM call, blocking on the result. The pre-PR-3
  LLMRunner did this before every LLM call; the ChatTurn
  preserves that behavior by calling into this module at the
  start of each `iterate/1` step.

  Returns:

    * `:proceed` if the existing messages fit
    * `{:compacted, messages}` if the compactor ran
    * `:stopped` if the user clicked Stop while waiting

  Blocks for up to 30 seconds; if the Agent doesn't respond
  the ChatTurn proceeds with the existing messages (avoids
  deadlock).
  """

  require Logger

  @timeout 30_000

  @doc """
  Send a preflight request to the Agent and block on the
  result. `state.ctx.agent_pid` is the Agent.
  """
  @spec run(Nest.Agents.Agent.ChatTurn.State.t()) ::
          :proceed | {:compacted, list()} | :stopped
  def run(state) do
    agent_pid = state.ctx.agent_pid
    messages = GenServer.call(agent_pid, :get_messages)
    send(agent_pid, {:preflight_request, self(), messages})

    receive do
      {:preflight_result, :proceed, _messages} ->
        :proceed

      {:preflight_result, :compacted, new_messages} ->
        {:compacted, new_messages}

      {:stop_chat, from} ->
        send(from, :stopped)
        :stopped
    after
      @timeout ->
        Logger.warning("Pre-flight request timed out; proceeding with existing messages")
        :proceed
    end
  end
end
