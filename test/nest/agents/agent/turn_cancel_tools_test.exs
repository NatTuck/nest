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
    backgrounded = %{make_ref() => %{pid: self(), ids: ["c2"]}}

    work = %Work{
      active_worker: self(),
      active_worker_kind: :tools,
      backgrounded: backgrounded
    }

    assert :ok = Turn.cancel_tools(state(work), reason)

    # Two pids, both this process: the active worker and the backgrounded batch.
    assert_receive {:cancel_tool, ^reason}
    assert_receive {:cancel_tool, ^reason}
    refute_receive {:cancel_tool, _}, 20
  end

  test "a turn with no worker running is a no-op" do
    assert :ok = Turn.cancel_tools(state(%Work{}), "changed")
    refute_receive {:cancel_tool, _}, 20
  end
end
