defmodule Nest.Agents.Agent.Machine.GiveUpTest do
  @moduledoc """
  Unit tests for the give-up's wording (`Machine.GiveUp`).

  The funnel that emits the action and the sites that rest through it are
  covered by `MachineDebtTest`; the audit table that lists those sites is
  checked against the sources by `GuardTest`; the refusal wording an operator
  sees is pinned on the banner the executor really broadcasts by
  `GiveUpDeliveryTest`.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine.GiveUp

  test "failure_reason/1 words the refusals an operator can act on" do
    # `:inbox_full` is pinned end-to-end by `GiveUpDeliveryTest` (the banner a
    # full inbox produces), so the clauses left here are the `{:status, _}` one,
    # which nothing else reaches, and one representative of the fallback that
    # `inspect/1`s everything else: `:not_found` and an exit share that clause.
    assert GiveUp.failure_reason({:status, :needs_repair}) ==
             "the agent is in a needs_repair state"

    assert GiveUp.failure_reason({:exit, :noproc}) == "{:exit, :noproc}"
  end

  test "notice_text/1 names the agent that did not answer" do
    # The one fact this file owns: the notice says *which* peer the runtime
    # stopped waiting for. That it arrives at all, and says "did not reply", is
    # `GiveUpDeliveryTest`'s and `ReplyDebtTest`'s.
    #
    # decision 4 also wants it framed as the runtime's words — no
    # `[Message from agent …]` label and no `[mode: …]` prefix. Neither absence
    # is assertable: both are *retired* spellings, and the header that would
    # frame the notice today (`[From agent … | mode: …]`) contains neither, so a
    # `refute` on them passes with the framing applied. `ReplyDebtTest` asserts
    # the same two spellings end to end, and is blind in the same way.
    assert GiveUp.notice_text("alice") =~ "\"alice\""
  end
end
