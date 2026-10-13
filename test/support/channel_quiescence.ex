defmodule Nest.TestSupport.ChannelQuiescence do
  @moduledoc """
  Lets the channels a test joined finish the message they are processing,
  before the test process (the SQL-sandbox connection owner) exits.

  ## The defect this closes

  A channel started by a test inherits `$callers` from the test process, so
  its `handle_in`/`handle_info` queries run on the test's checked-out sandbox
  connection. The channel also dies *with* the test process. A channel still
  processing a message when the test body ends is therefore killed mid-query,
  and `DBConnection.Ownership.Proxy` — which still has that channel registered
  as the connection's client — takes its disconnect branch when the owner's
  `:DOWN` arrives:

      Postgrex.Protocol (#PID<…>) disconnected: ** (DBConnection.ConnectionError)
      owner #PID<…> exited

  That is `:error` output from a test run, which this repo does not allow, and
  it is the same invariant `AgentTestLifecycle.assert_zero_remaining!/1`
  enforces for agents — a test may not finish with an outstanding child. A
  channel is such a child, and the teardown's agent discovery cannot see it.

  ## Why a synchronous call and not an event

  The rest of the suite waits for events rather than for state, and that is
  right: an event is what the code under test publishes. Here there is no
  event to wait for — a channel that reconciles its subscriptions does so
  without emitting a frame — and the wait cannot be skipped, because the
  process is about to be killed. A synchronous call to the channel is not a
  poll and does not sample state: the channel handles messages in order, so
  the call returns only once every message queued before it has been handled,
  which is exactly "this channel is idle now".

  Best effort on purpose: a channel that will not answer inside the bound is
  left alone rather than turned into a new teardown failure. This is a
  quiescence aid, not an assertion — the assertion is
  `assert_zero_remaining!/1`, and a channel that refuses to drain is reported
  by the disconnect it goes on to cause.
  """

  @drain_ms 1_000

  @doc """
  Drain every channel the current test joined. No-op when the test joined
  none, or when a channel is already gone.
  """
  @spec drain() :: :ok
  def drain do
    for pid <- Process.get(:nest_joined_channels, []),
        is_pid(pid),
        Process.alive?(pid) do
      drain_one(pid)
    end

    :ok
  end

  defp drain_one(pid) do
    # allowlist: barrier — the channel's mailbox is drained so it cannot be
    # killed mid-query when this test process (the sandbox owner) exits; there
    # is no event to wait for, because the reconcile emits no frame.
    _ = :sys.get_state(pid, @drain_ms)
    :ok
  catch
    # `:sys.get_state` exits on timeout, and a channel may legitimately be gone
    # by now (a test that stopped it, or one that crashed).
    :exit, _reason -> :ok
  end
end
