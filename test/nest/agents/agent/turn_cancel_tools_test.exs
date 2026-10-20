defmodule Nest.Agents.Agent.TurnCancelToolsTest do
  @moduledoc """
  `Turn.cancel_tools/2` — the space edit's cancellation of a turn's in-flight tool
  work.

  It is not a stop: nothing ends the turn, nothing is finalized and no reply is
  given up. Each worker the machine is running is told to stop its command and
  report a tool error, and a worker that is not running a command (the http
  worker) simply never matches the message.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ChatState.Live
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Work
  alias Nest.Agents.Agent.Turn

  defp state(work) do
    %Agent{live: %Live{machine: %Machine{work: work}}}
  end

  test "the active worker and every backgrounded batch are told, with the reason" do
    reason = "The space's environment changed; this call did not run."

    # Two backgrounded batches, not one: with a single batch, "the active worker"
    # and "every batch" are the same two sends, so an implementation that told
    # only the first batch would still pass.
    backgrounded = %{
      make_ref() => %{pid: self(), ids: ["c2"]},
      make_ref() => %{pid: self(), ids: ["c3"]}
    }

    work = %Work{
      active_worker: self(),
      active_worker_kind: :tools,
      backgrounded: backgrounded
    }

    assert :ok = Turn.cancel_tools(state(work), reason)

    # Three pids, all this process: the active worker and both batches. `send/2`
    # to a local pid is in the mailbox before `cancel_tools/2` returns, so there
    # is no later event to wait for — these read the mailbox as the call left it,
    # and the refute is a fact about a call that has already happened rather than
    # a bet on a window.
    assert_received {:cancel_tool, ^reason}
    assert_received {:cancel_tool, ^reason}
    assert_received {:cancel_tool, ^reason}
    refute_received {:cancel_tool, _}
  end

  test "a turn with no worker running is a no-op" do
    assert :ok = Turn.cancel_tools(state(%Work{}), "changed")
  end
end
