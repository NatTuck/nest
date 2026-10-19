defmodule Nest.Agents.Agent.NoticeDeliveryTest do
  @moduledoc """
  `NoticeDelivery.outcome/3` classifies what a settle did with a notice pair:
  appended, carried by a compaction, or neither.

  Pure over `Agent.t()` and `Machine.t()` — no process, no DB, no settle — so the
  three arms are driven directly instead of through an agent.

  What the call sites' tests pin is the *append*: the pair's text in the
  transcript. The `:appended` classification has no other distinguishing
  observable there — the only difference between it and a failed delivery is the
  absence of a `Logger.warning`, and `SMELLS.md` forbids asserting on the absence
  of a log line (a capture is global, so the assertion flakes and tests nothing).
  That is why the arm is pinned here, on its inputs, and not by a log assertion
  at the call site.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.NoticeDelivery
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

  @text "the notice"

  test "an appended pair is :appended, and an earlier pair with the same text is not" do
    earlier = pair()
    before = agent([system(), earlier])

    # The row `text` names is *already* in the transcript, from an earlier
    # change: a settle that adds nothing must not be read as having appended it.
    # That is what the `Enum.drop(length(before.chat_state.messages))` diff is
    # for.
    assert NoticeDelivery.outcome(before, before, @text) == {:error, :idle}

    # A settle that added the pair is `:appended`, even with the earlier one
    # behind it.
    settled = agent(before.chat_state.messages ++ pair())

    assert NoticeDelivery.outcome(before, settled, @text) == :appended

    # ...and a *different* text is not this notice, whatever else landed.
    assert NoticeDelivery.outcome(before, settled, "another notice") == {:error, :idle}
  end

  test "a notice on a compaction's entry is :deferred, and a blocked machine is an error" do
    before = agent([system()])

    # The notice is in flight: on the compaction's entry, which is the only place
    # a notice can be staged from.
    staged = %{
      before
      | live: %{
          before.live
          | machine: %Machine{entry: {:compaction, nil, %{kind: :model}}}
        }
    }

    assert NoticeDelivery.outcome(before, staged, @text) == :deferred

    # Nothing appended and nothing in flight: the status says where the machine
    # ended up, and the caller decides what that means for it.
    blocked = %{before | live: %{before.live | machine: %Machine{phase: :context_overflow}}}

    assert NoticeDelivery.outcome(before, blocked, @text) == {:error, :context_overflow}
  end

  defp agent(messages) do
    %Agent{
      chat_state: %Agent.ChatState{messages: messages},
      live: %Agent.ChatState.Live{machine: %Machine{}}
    }
  end

  defp system do
    {:system, %Nest.Messages.System{index: 0, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp pair do
    [
      {:user, %User{index: 1, parts: [%Part.Text{text: @text}], api_logs: []}},
      {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "ok"}], api_logs: []}}
    ]
  end
end
