defmodule Nest.Agents.Agent.Broadcasts.NeedsRepairTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Broadcasts.NeedsRepair` — the helper
  that emits a `chat:status` push for an agent whose persisted active
  sequence failed wire validation at load (status `:needs_repair`).
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Broadcasts.NeedsRepair

  describe "broadcast/4 wire shape" do
    test "status, violations and repair command ride the chat:status payload" do
      space_id = System.unique_integer([:positive])
      violations = [%{rule: :tool_pairing, position: 2}]

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:test-repair")

      NeedsRepair.broadcast(
        space_id,
        "test-repair",
        violations,
        "mix nest.repair_messages --space clever-raven"
      )

      assert_receive {:chat_status, payload}, 500
      assert payload.status == "needs_repair"
      assert payload.sequenceViolations == violations
      assert payload.repairCommand == "mix nest.repair_messages --space clever-raven"
    end
  end
end
