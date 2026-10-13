defmodule Nest.Agents.AgentTestLifecycle do
  @moduledoc """
  Lifecycle helpers for the agent test suite — separate
  from `AgentTestHelpers` so the test support file stays
  under the credo 500-line cap.

  Exposes:

    * `wait_for_pid_down/3` — the single-message `:DOWN` wait used
      by `AgentTestHelpers` to synchronize GenServer shutdown before
      the test exits its sandbox checkout. (Drain loops are explicitly
      forbidden here — see the impl for the rationale.)
    * `stop_test_agents/0` — the in-process teardown that runs before
      the test process (the sandbox connection owner) exits. It
      *discovers* every agent belonging to the current test via the
      global `Nest.Agents.Registry` (every agent registers itself in
      `Agent.start_link/1`, including production-spawned children and
      `start_supervised!` pids), scoped to the spaces the test created
      (visible in the test's sandbox transaction). No per-test
      registration is required. Each discovered agent is asked for its
      own status, in its own process (`Agent.ClientAPI.get_status/2`),
      *before* any of them is stopped — so the in-flight check is
      answered by the agent it is about and cannot be answered by a
      clock.
    * `assert_zero_remaining!/1` — asserts that the teardown left
      nothing behind. The caller decides whether to assert, so cleanup
      can never mask an unrelated body failure.
    * `reraise_after_teardown/3` — the failing path of a wrapped test
      body: teardown, then re-raise the body's failure untouched.

  ## Why this cannot be an `on_exit`

  ExUnit runs `on_exit` callbacks in a separate runner process *after*
  the test process has exited. The test process is the SQL-sandbox
  connection owner, so by the time `on_exit` runs, the connection is
  already gone. An agent still processing a chat turn would then fail
  its `MessageAppender.append_one/2` insert with a Postgrex
  "owner exited" error. Running in the test body (via the `test`
  wrapper in `Nest.TestSupport.AgentTestMacro`) keeps the sandbox
  checkout alive.
  """

  import Ecto.Query

  alias Nest.Agents.Agent.ClientAPI
  alias Nest.Agents.Registry
  alias Nest.Repo
  alias Nest.Spaces.Space

  # Observable status values that mean an LLM/tool/compaction turn is
  # actively running. Every other value (`:idle`, `:model_missing`,
  # `:context_overflow`, `:compaction_failed`,
  # `:compaction_loop_detected`) is a terminal/frozen state where no
  # turn is in flight, so the agent cannot write to the DB anymore.
  @in_flight_statuses [:streaming, :executing_tools, :compacting]

  # How long teardown waits for one agent to answer its own status question
  # (`Agent.ClientAPI.get_status/2`) before giving up on that agent and stopping
  # it anyway. It is not a failure bound and not a measurement of the agent: it
  # decides nothing, because a non-answer is not a status (see `agent_status/1`).
  # It stays at 250 — the value of the `:sys.get_state` probe it replaces — so
  # what one agent can cost the teardown is unchanged (`@answer_ms` +
  # `@stop_ms`, exactly what the probe plus the stop cost).
  #
  # Sizing, from the real thing this time: 473 teardown answers across a full
  # suite at `max_cases: 16` (seed 12345) took p50 21 us, p90 44 us, p99 84 us,
  # p99.9 308 us, max 3.3 ms. 250 ms is ~76x that max, so it is headroom for a
  # healthy agent, not a latency budget. What it costs: an agent that is busy in
  # its own loop (a DB append under pool contention) for longer than this is no
  # longer *diagnosed* as in flight — the old probe called that "in flight", and
  # that same non-answer is what made a *dying* agent a false positive. A clock
  # cannot tell the two apart, which is why it is gone.
  @answer_ms 250

  # Cleanup headroom for the stop itself: `stop_pid/2`'s `:DOWN` wait, and
  # `wait_for_pid_down/3`'s. It is a single `:DOWN` receive, so it costs nothing
  # on the happy path and only bounds a failure: an agent's
  # `terminate/2` walks its descendant tree and removes its tmp directory, so a
  # busy scheduler can push shutdown past a fixed short window. A genuinely
  # wedged agent still blows the bound (and is then reported by
  # `assert_zero_remaining!/1`).
  @stop_ms 2_000

  @doc """
  Send `:shutdown` to the agent pid and wait for its
  `:DOWN` (single-message receive, not a drain loop).
  No-op if the pid is already gone. Public so tests can
  call it directly without re-implementing the pattern.

  `Process.monitor/1` registers the DOWN subscription
  before `Process.exit/2` so the receive can't miss the
  event even if the pid was already dead at monitor-time
  (returns `:DOWN, :noproc`). `Process.demonitor/1, [:flush]`
  on timeout cleans up any pending DOWN.

  The timeout is cleanup headroom, not a latency assertion: an
  agent's `terminate/2` walks its descendant tree and removes its
  tmp directory, so a busy scheduler can push shutdown past a
  fixed short window. A genuinely wedged agent still blows the
  bound (and is then reported by `assert_zero_remaining!/1`).
  """
  @spec wait_for_pid_down(integer(), String.t(), pos_integer()) :: :ok
  def wait_for_pid_down(space_id, name, timeout \\ @stop_ms) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        stop_pid(pid, timeout)

      _ ->
        :ok
    end
  end

  @doc """
  Stop every agent owned by the current test and return the
  violations that the caller should assert on (see
  `assert_zero_remaining!/1`).

  Discovery is structural: `Nest.Agents.Registry.list_all/0` returns
  every live agent, and an agent belongs to this test iff its space
  row is visible in the test's sandbox transaction (concurrent async
  tests' uncommitted spaces are invisible). This catches
  production-spawned children (clone / `agents-spawn`) and
  `start_supervised!({Agent, _})` pids without any per-test
  registration.

  Returns `%{owned: non_neg_integer(), in_flight: [...], still_alive:
  [...]}`. Read every status, then stop every agent with a single
  `:DOWN` wait each, no loops. The caller decides whether to raise so
  that cleanup cannot mask an unrelated body failure.
  """
  @spec stop_test_agents() :: map()
  def stop_test_agents do
    owned = owned_agents()

    # Sample before stopping anything. The teardown's own stops perturb the
    # agents it is about to read: stopping one agent starts a turn on another
    # (a batch's child terminating makes its parent continue the batch), so a
    # read taken *after* a stop reports the state the cleanup created instead of
    # the state the test left behind. Measured on
    # `agents_batch_test.exs`'s coordinator-death test, which read `:streaming`
    # for exactly that reason.
    in_flight =
      for {space_id, name, pid} <- owned,
          status = agent_status(pid),
          status in @in_flight_statuses do
        {space_id, name, status}
      end

    Enum.each(owned, fn {_space_id, _name, pid} -> stop_pid(pid, @stop_ms) end)

    still_alive = for {space_id, name, pid} <- owned, Process.alive?(pid), do: {space_id, name}

    %{owned: length(owned), in_flight: in_flight, still_alive: still_alive}
  end

  @doc """
  Raise the explicit "zero remaining agents for this test" assertion
  when `stop_test_agents/0` reported a violation: an owned agent still
  alive after teardown, or an owned agent that was still in flight
  (`Machine.status_for/1` in `[:streaming, :executing_tools, :compacting]`) when
  the test body finished.
  """
  @spec assert_zero_remaining!(map()) :: :ok
  def assert_zero_remaining!(%{owned: owned, in_flight: in_flight, still_alive: still_alive}) do
    cond do
      still_alive != [] ->
        raise "expected zero remaining agents for this test, but these were still " <>
                "alive after teardown: #{inspect(still_alive)}"

      in_flight != [] ->
        raise "expected zero remaining agents for this test, but these were still " <>
                "in flight at test finish: #{inspect(in_flight)} " <>
                "(owned: #{owned})"

      true ->
        :ok
    end
  end

  @doc """
  Teardown for the *failing* path of a wrapped test body: stop the
  test's agents, then re-raise the body's failure untouched.

  `Nest.TestSupport.AgentTestMacro` wraps every test body, so this runs
  in the test process (the sandbox owner) while the connection is still
  checked out. Without it, a test that failed while an agent was still
  mid-turn would leave that agent running past the sandbox check-in
  (`Nest.DataCase.setup_sandbox/2` does it in `on_exit`, i.e. after this
  process exits) and its next insert would fail with a Postgrex "owner
  exited" error — noise that would obscure the real failure. Agents
  trap exits (`Nest.Agents.Agent.init/1`), so a dying test process does
  not stop them synchronously.

  The zero-remaining invariant is deliberately NOT asserted here: the
  body already failed, and cleanup must never mask that. `:erlang.raise/3`
  (not `reraise/2`) is used so `:throw`/`:exit` failures are re-raised
  too, with the original stacktrace.
  """
  @spec reraise_after_teardown(:error | :exit | :throw, term(), Exception.stacktrace()) ::
          no_return()
  def reraise_after_teardown(kind, reason, stacktrace) do
    _ = stop_test_agents()
    :erlang.raise(kind, reason, stacktrace)
  end

  # Every agent the current test owns: registered live agents whose
  # space was created inside this test's sandbox transaction.
  defp owned_agents do
    all = Registry.list_all()
    visible = visible_space_ids(all)

    for {space_id, name} <- all,
        space_id in visible,
        pid = lookup_pid(space_id, name),
        is_pid(pid) do
      {space_id, name, pid}
    end
  end

  # Spaces visible to the current test's sandbox transaction. Other
  # concurrent tests' spaces are uncommitted, so a plain scan returns
  # only this test's spaces — no need to build an IN-list from every
  # live agent's space id (which grows with suite concurrency).
  defp visible_space_ids(_entries) do
    Repo.all(from(s in Space, select: s.id))
  end

  defp lookup_pid(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  # The agent's own status, read in its own process: `Machine.status_for/1` is
  # evaluated by the agent, so nothing is sampled from outside and no clock
  # stands in for a status. Three outcomes, and only the first is a status:
  #
  #   * the agent answers   -> that is its status, exactly. A *mid-turn* agent
  #     answers: a turn runs in a worker task, not in the agent's loop, so
  #     `:streaming`/`:executing_tools`/`:compacting` is the in-flight signal.
  #   * the agent goes away -> the call exits with the reason it went away
  #     (`:noproc`/`:shutdown`/a crash), which is `nil` here: no process is left
  #     to run a turn. This is the race that produced the false positive — a
  #     test body that already stopped its agent leaves it mid-`terminate/2`,
  #     and an agent that is being stopped is not in flight.
  #   * the agent never answers -> `:timeout` (dying behind a contended
  #     synchronous call, or wedged), which is also `nil` and not a status. A
  #     process that will not stop is reported by `still_alive` instead, which
  #     says what is actually wrong with it.
  defp agent_status(pid) do
    ClientAPI.get_status(pid, @answer_ms)
  catch
    :exit, _reason -> nil
  end

  defp stop_pid(pid, timeout) do
    # Unlink first: test-started agents are linked to the test pid so
    # an unexpected crash fails the test. A deliberate `:shutdown`
    # would otherwise propagate to (and kill) the test pid.
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    await_down(ref, pid, timeout)
  end

  # A single `:DOWN` receive — never a drain loop. `Process.monitor/1` runs
  # before the exit signal, so the receive cannot miss the event even if the pid
  # was already dead at monitor-time (`:DOWN, :noproc`). `Process.demonitor/1,
  # [:flush]` on timeout cleans up any pending DOWN.
  defp await_down(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end
end
