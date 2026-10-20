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

  # A pid that receives but never consumes: `receive` with one explicit pattern
  # leaves anything else in the mailbox. `cancel_tools/2` sends with `send/2` from
  # the caller, and a send to a local pid is in that pid's mailbox before it
  # returns, so the mailbox is the call's whole effect and reading it needs no
  # window.
  defp destination do
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # Every message the pid has been sent, oldest first.
  defp received(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    messages
  end

  test "the active worker and every backgrounded batch are told, with the reason" do
    reason = "The space's environment changed; this call did not run."

    # Two backgrounded batches, not one: with a single batch, "the active worker"
    # and "every batch" are the same two sends, so an implementation that told
    # only the first batch would still pass. And each target is its own process,
    # because three pids all equal to the test process would make "the cancel went
    # to the wrong target" and "one target was told twice" read exactly like the
    # correct send.
    active = destination()
    batch1 = destination()
    batch2 = destination()

    backgrounded = %{
      make_ref() => %{pid: batch1, ids: ["c2"]},
      make_ref() => %{pid: batch2, ids: ["c3"]}
    }

    work = %Work{
      active_worker: active,
      active_worker_kind: :tools,
      backgrounded: backgrounded
    }

    assert :ok = Turn.cancel_tools(state(work), reason)

    # One message each, with the reason: the whole mailbox, so a target told twice
    # fails here as surely as one told not at all.
    assert received(active) == [{:cancel_tool, reason}]
    assert received(batch1) == [{:cancel_tool, reason}]
    assert received(batch2) == [{:cancel_tool, reason}]

    # And nothing else was told: this process names no target, so a cancel in its
    # own mailbox came from somewhere the state does not.
    refute_received {:cancel_tool, _}
  end

  test "a turn with no worker running is a no-op" do
    assert :ok = Turn.cancel_tools(state(%Work{}), "changed")
  end
end
