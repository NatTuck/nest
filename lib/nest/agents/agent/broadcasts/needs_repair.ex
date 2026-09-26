defmodule Nest.Agents.Agent.Broadcasts.NeedsRepair do
  @moduledoc """
  Broadcasts a `chat:status` event for an agent whose persisted active
  sequence failed the wire preflight at load (status
  `:needs_repair`). Extracted from `Nest.Agents.Agent.Broadcasts` so
  the parent module stays under the credo 500-line cap.

  The channel subscribers drive `NeedsRepairBanner` from the
  `payload.status === "needs_repair"` marker; the structured
  violations and the offline repair command ride along for display.
  """

  alias Nest.PubSub

  def broadcast(space_id, name, violations, repair_command) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{space_id}:#{name}",
      {:chat_status,
       %{
         status: "needs_repair",
         sequenceViolations: violations,
         repairCommand: repair_command
       }}
    )
  end
end
