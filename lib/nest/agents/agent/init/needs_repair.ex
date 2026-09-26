defmodule Nest.Agents.Agent.Init.NeedsRepair do
  @moduledoc """
  Marks a restored agent's state `:needs_repair` when its persisted
  active message sequence failed the wire preflight at load
  (`notes/enforce-mesages-seq-invariants.md` §4).

  The agent process still starts so its history stays viewable, but
  `live.status` becomes `:needs_repair`:
  `Nest.Agents.Agent.Callbacks.chat_or_drop/3` and the agent channel
  both refuse `chat:message`, and a `chat:status` broadcast tells the
  UI to show the repair banner. Recovery is offline: run
  `mix nest.repair_messages`, then reload the agent.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.LLM.Preflight

  @spec block(Nest.Agents.Agent.t(), [Preflight.violation()], String.t() | nil) ::
          Nest.Agents.Agent.t()
  def block(state, violations, repair_command) do
    state = %{
      state
      | live: %{
          state.live
          | status: :needs_repair,
            sequence_violations: violations,
            repair_command: repair_command
        }
    }

    Logger.error(
      "Agent #{state.name} (space #{state.space_id}) loaded an invalid active " <>
        "message sequence (#{length(violations)} wire violation(s)); blocking chat. " <>
        "Repair with: #{repair_command || "mix nest.repair_messages --all"}"
    )

    Broadcasts.needs_repair(state.space_id, state.name, violations, repair_command)

    state
  end
end
