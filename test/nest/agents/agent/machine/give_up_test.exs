defmodule Nest.Agents.Agent.Machine.GiveUpTest do
  @moduledoc """
  Unit tests for the give-up's wording (`Machine.GiveUp`).

  The funnel that emits the action and the sites that rest through it are
  covered by `MachineDebtTest`; the audit table that lists those sites is
  checked against the sources by `GuardTest`.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine.GiveUp

  test "failure_reason/1 words the refusals an operator can act on" do
    # The two refusals with a human-readable cause, and the fallback for
    # everything else (a missing peer, an exit): the banner says what happened
    # rather than only that something did.
    assert GiveUp.failure_reason(:inbox_full) == "the agent's inbox is full"

    assert GiveUp.failure_reason({:status, :needs_repair}) ==
             "the agent is in a needs_repair state"

    assert GiveUp.failure_reason(:not_found) == ":not_found"
    assert GiveUp.failure_reason({:exit, :noproc}) == "{:exit, :noproc}"
  end

  test "notice_text/1 names the agent that did not answer and quotes nothing else" do
    # decision 4's instinct applied to the give-up: the requester already has the
    # query, and the runtime reports a fact about a peer rather than speaking for
    # it — so no `[Message from agent …]` label and no `[mode: …]` prefix.
    text = GiveUp.notice_text("alice")

    assert text =~ "\"alice\""
    assert text =~ "did not reply"
    refute text =~ "Message from agent"
    refute text =~ "[mode:"
  end
end
