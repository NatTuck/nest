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

  That is `:error` output from a test run, which this repo does not allow. The
  channel is an outstanding child of the test, so it falls under the invariant
  `AgentTestLifecycle.assert_zero_remaining!/1` *enforces* for agents — a test
  may not finish with an outstanding child — but the teardown's agent discovery
  cannot see a channel. Draining is this module's half of *serving* that
  invariant; it does not enforce it, because a drain is best effort (below).

  ## What this covers, and what it does not

  It covers channels joined through `NestWeb.ChannelCase.subscribe_and_join/2,3,4`
  **from the test process**, because that is where the wrapper records them:
  the record goes into the calling process's dictionary, and `drain/0` reads the
  dictionary of the process the teardown runs in. A channel joined from inside a
  spawned process is therefore neither recorded nor drained.

  So this closes the window for the class it covers, not for every way a process
  can borrow the sandbox connection. A `Task.Supervisor` child that queries the
  owner's connection is still able to outlive the test body; that class needs the
  same treatment (a registry the teardown can read), and until it has one it is
  unguarded.

  ## Why a synchronous call and not an event

  The rest of the suite waits for events rather than for state, and that is
  right: an event is what the code under test publishes. Here there is no
  event to wait for — a channel that reconciles its subscriptions does so
  without emitting a frame — and the wait cannot be skipped, because the
  process is about to be killed. A synchronous call to the channel is not a
  poll and does not sample state: the channel handles messages in order, so
  the call returns only once every message queued before it has been handled,
  which is exactly "this channel is idle now".

  ## The bound, and what a give-up does

  `@drain_ms` bounds **one channel**, and `drain/0` drains them sequentially, so
  the worst case for a single test is one bound per channel it joined — there is
  no single bound for the drain as a whole.

  Best effort on purpose: a channel that will not answer inside its bound is
  left alone rather than turned into a new teardown failure — a drain is a
  quiescence aid, not an assertion, and the assertion is
  `assert_zero_remaining!/1`. But it is never *silent*: a give-up is logged at
  `:error`, naming the channel's topic and the bound, because a give-up means
  the channel may still be mid-query when the owner exits, which is the exact
  state that produces the disconnect this module exists to prevent. A clean run
  therefore has no such line, and a run that does has said why.
  """

  require Logger

  @drain_ms 1_000

  @doc """
  Drain every channel the current test joined. No-op when the test joined
  none, or when a channel is already gone.
  """
  @spec drain() :: :ok
  def drain do
    for {pid, topic} <- Process.get(:nest_joined_channels, []),
        is_pid(pid),
        Process.alive?(pid) do
      drain_one(pid, topic)
    end

    :ok
  end

  defp drain_one(pid, topic) do
    # allowlist: barrier — the channel's mailbox is drained so it cannot be
    # killed mid-query when this test process (the sandbox owner) exits; there
    # is no event to wait for, because the reconcile emits no frame.
    _ = :sys.get_state(pid, @drain_ms)
    :ok
  catch
    :exit, reason ->
      # A channel that is already gone (a test stopped it, or it crashed) has
      # nothing to drain and says nothing. A channel that is still *alive* and
      # would not answer inside the bound is the opposite: it may still be
      # mid-query when the owner exits, which is exactly the state that
      # produces the "owner … exited" disconnect this module exists to prevent.
      # Give up without failing the test (a drain is not an assertion, and a
      # teardown failure must not mask a body failure), but never silently —
      # a give-up has to leave a trace in the run's output.
      if Process.alive?(pid) do
        Logger.error(
          "channel drain gave up after #{@drain_ms} ms on channel #{inspect(topic)} " <>
            "(#{inspect(pid)}, #{inspect(Process.info(pid, :initial_call))}): it may " <>
            "still be using this test's sandbox connection when the owner exits. " <>
            "Reason: #{inspect(reason)}"
        )
      end

      :ok
  end
end
