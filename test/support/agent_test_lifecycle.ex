defmodule Nest.Agents.AgentTestLifecycle do
  @moduledoc """
  Lifecycle helpers for the agent test suite — separate
  from `AgentTestHelpers` so the test support file stays
  under the credo 500-line cap.

  Exposes:

    * `wait_for_pid_down/2,3` — the single-message `:DOWN` wait used to
      synchronize GenServer shutdown. It has no give-up: an agent that
      does not die inside the bound raises. The 2-arity form uses the
      tight detector bound (`@stop_ms`); a caller that is cleaning up
      rather than fencing a test body passes the cleanup bound
      (`cleanup_ms/0`) as the third argument. (Drain loops are explicitly
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
    * `detect_leaked_agent/2,3` — the `on_exit` check for the path the
      in-process teardown cannot cover: a test killed at its per-test
      deadline skips the wrapper, so an agent not linked to the test
      process leaks. The hook only *watches* (see `detect_leaked_agent/2`).
    * `cleanup_ms/0` — the bound that check waits; `wait_for_pid_down/2`'s
      `@stop_ms` default is the tight detector, not this.

  ## Why this cannot be an `on_exit`

  ExUnit runs `on_exit` callbacks in a separate runner process *after*
  the test process has exited. The test process is the SQL-sandbox
  connection owner, so by the time `on_exit` runs, the connection is
  already gone. An agent still processing a chat turn would then fail
  its `MessageAppender.append_one/2` insert with a Postgrex
  "owner exited" error. Running in the test body (via the `test`
  wrapper in `Nest.TestSupport.AgentTestMacro`) keeps the sandbox
  checkout alive. For the same reason the `on_exit` hooks
  `AgentTestHelpers` registers issue no query and never stop an agent:
  they can only *report* what the wrapper could not (see
  `detect_leaked_agent/2`). (`supervisor_subagent_test.exs`'s `safe_stop/2`
  is the one hook in this tree that stops an agent from an `on_exit`; it
  stops only an idle child, whose `terminate/2` issues no query — so the
  rule holds for the hook, not because the hook obeys it.)
  """

  import Ecto.Query

  require Logger

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
  # it anyway. Not a failure bound and not a measurement of the agent: a
  # non-answer is not a status (see `agent_status/1`), so the bound can no longer
  # make a *starved* agent read as in flight. What it does decide is the guard's
  # one blind spot: an agent busy in its own loop (a DB append under pool
  # contention) for longer than this is not *diagnosed* as in flight, and
  # `agent_test_lifecycle_test.exs` pins that boundary as a test rather than a
  # comment. It stays at 250 — the value of the `:sys.get_state` probe it
  # replaces — so the *answer* half of what one agent can cost the teardown
  # (`@answer_ms` + `@stop_ms`) is unchanged. The stop half is not: it is now
  # the 10 ms detector (`@stop_ms`), not the multi-second bound the probe used
  # to be paired with, so the total is far lower.
  #
  # The one measurement behind it is a single, right-censored run: 473 answers at
  # `max_cases: 16` took p50 21 us / p99 84 us / max 3.3 ms. A read that does not
  # answer inside the bound is a timeout, not a latency, so the sample cannot say
  # how often a healthy agent fails to answer — and this repo's loaded
  # measurement (48 CPU burners: p50 926 ms, max 1534 ms) shows the bound *can* be
  # reached under load. Command and caveats: `notes/sketchy-slow-tests.md` §11.
  @answer_ms 250

  # How long one agent's stop waits for its `:DOWN` after
  # `Process.exit(pid, :shutdown)`, before the teardown hard-fails naming that
  # agent. This is a **detector**, not headroom: see `stop_pid/2` for why a
  # compliant test's agent is parked in its receive loop when the test ends, and
  # therefore why the handshake is meant to be microseconds. A bound a busy
  # agent can sit under would not detect anything.
  #
  # The number comes from a measurement, not a preference. Instrumenting the
  # handshake in-memory (`:counters`, so the probe adds no I/O to what it
  # measures) and running the whole suite at `max_cases: 16` on an idle machine
  # (seed 12345), the 479 clean-path handshakes took p50 130 us / p90 250 us /
  # p99 1.1 ms / max 4.4 ms. The tail is not the agent: it is the scheduler
  # under the suite's own concurrency (the suite is contention-bound above its
  # physical core count — 8 cases is much tighter, and `notes/sketchy-slow-tests.md`
  # §11 has the 8/16/24 numbers), and it survives moving every cross-process
  # call out of `Agent.terminate/2`. 10 ms is the smallest value that clears the
  # measured max with real room (~2.3x) — and it is the ceiling the design
  # allows: a clean path that needed more would mean the detector's premise was
  # wrong, not that the bound should grow.
  @stop_ms 10

  # The cleanup bound. Unlike `@stop_ms` this is **not** a detector policing an
  # invariant a compliant test already holds; it is the safety net for the path
  # where the test was killed at its per-test deadline, so the in-process
  # teardown (`stop_test_agents/0`, run by the `test` wrapper) never ran and only
  # the `on_exit` hook is left. That hook runs after the sandbox owner has
  # exited, so it can neither query nor stop an agent — `terminate/2` can query
  # — it can only watch (`detect_leaked_agent/2`).
  #
  # Generous on purpose, and the generosity is nearly free: the wait is a monitor
  # plus a single `:DOWN` receive, so a healthy agent pays microseconds and only
  # a real leak reaches the bound. The measured handshake behind `@stop_ms`
  # (p50 130 us / p99 1.1 ms / max 4.4 ms at `max_cases: 16` on an idle machine)
  # is what 2000 clears with room, and `notes/sketchy-slow-tests.md` §5 is the
  # ruling on the value ("a long ceiling is free and a short one is a flake ...
  # lowering it needs a measurement, not a preference"); §11 has the loaded
  # numbers.
  @cleanup_ms 2_000

  @doc """
  The cleanup bound: how long an `on_exit` wait gives an agent to go away
  before it reports the agent as leaked. See `@cleanup_ms`.
  """
  @spec cleanup_ms() :: pos_integer()
  def cleanup_ms, do: @cleanup_ms

  @doc """
  Report `space_id`/`name` as leaked if the agent has not gone away within
  `timeout` (default `cleanup_ms/0`).

  The in-process teardown runs inside the `test` wrapper, so a test killed at
  its per-test deadline skips it entirely: ExUnit kills the test process
  outright, the wrapper's `catch`/`else` never runs, and only the `on_exit`
  hooks are left. An agent linked to the test process dies on its own when that
  process dies; an unlinked one does not, and with no check it leaks silently
  into the rest of the run.

  This is that check. It only *watches* — a monitor and a bounded receive — so
  it is safe in the `on_exit` process, which does not own the test's sandbox
  connection. A leaked agent is reported (an `error` log) and returned as
  `{:leaked, space_id, name}`, never forced: a stop would run `terminate/2`,
  which can query on that dead connection.

  The report says only what this hook can observe — the agent is still alive
  after its test, so the teardown did not stop it. It does **not** name a cause:
  a deadline kill and a `stop_pid/2` that gave up at `@stop_ms` look the same
  from here, and they are different diagnoses.
  """
  @spec detect_leaked_agent(integer(), String.t(), pos_integer()) ::
          :ok | {:leaked, integer(), String.t()}
  def detect_leaked_agent(space_id, name, timeout \\ @cleanup_ms) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} -> watch_for_leak(space_id, name, pid, timeout)
      _ -> :ok
    end
  end

  defp watch_for_leak(space_id, name, pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])

        Logger.error(
          "agent #{space_id}/#{name} is still alive after its test: the " <>
            "in-process teardown did not stop it, so it is leaked into the rest " <>
            "of the run"
        )

        {:leaked, space_id, name}
    end
  end

  @doc """
  Send `:shutdown` to the agent registered as `space_id`/`name` and wait for
  its `:DOWN` (a single-message receive, not a drain loop). A no-op if the
  agent is already gone.

  Raises when the agent does not die inside `timeout`: the wait is the
  teardown's detector (`stop_pid/2`), so it has no give-up. Public so a test
  that stops an agent itself can synchronize on the same event.
  """
  @spec wait_for_pid_down(integer(), String.t(), pos_integer()) :: :ok
  def wait_for_pid_down(space_id, name, timeout \\ @stop_ms) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        case stop_pid(pid, timeout) do
          :ok -> :ok
          :timeout -> raise_not_stopped([{space_id, name}], timeout)
        end

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

  Returns `%{owned: non_neg_integer(), in_flight: [...], not_stopped:
  [...]}`. Read every status, then stop every agent with a single
  `:DOWN` wait each, no loops. Every agent is stopped even when one of
  them does not die in time, so a failure reports the whole set; the
  caller decides whether to raise, so cleanup cannot mask an unrelated
  body failure.
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

    not_stopped =
      Enum.flat_map(owned, fn {space_id, name, pid} ->
        case stop_pid(pid, @stop_ms) do
          :ok -> []
          :timeout -> [{space_id, name}]
        end
      end)

    %{owned: length(owned), in_flight: in_flight, not_stopped: not_stopped}
  end

  @doc """
  Raise the explicit "zero remaining agents for this test" assertion
  when `stop_test_agents/0` reported a violation: an owned agent that did
  not die inside `@stop_ms` of `:shutdown`, or an owned agent that was still
  in flight (`Machine.status_for/1` in `[:streaming, :executing_tools,
  :compacting]`) when the test body finished.
  """
  @spec assert_zero_remaining!(map()) :: :ok
  def assert_zero_remaining!(%{owned: owned, in_flight: in_flight, not_stopped: not_stopped}) do
    cond do
      not_stopped != [] ->
        raise "expected zero remaining agents for this test, but these did not stop " <>
                "within #{@stop_ms} ms of :shutdown: #{inspect(not_stopped)} " <>
                "(owned: #{owned})"

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
  body already failed, and cleanup must never mask that. A teardown
  failure is therefore reported in the log rather than raised — Erlang
  exceptions carry no cause chain, so it cannot be attached to the body's
  exception without changing the exception the body raised, and masking a
  real cause with a cleanup error is worse than the leak. `:erlang.raise/3`
  (not `reraise/2`) is used so `:throw`/`:exit` failures are re-raised
  too, with the original stacktrace.
  """
  @spec reraise_after_teardown(:error | :exit | :throw, term(), Exception.stacktrace()) ::
          no_return()
  def reraise_after_teardown(kind, reason, stacktrace) do
    log_teardown_failure(safe_stop_test_agents())
    :erlang.raise(kind, reason, stacktrace)
  end

  # The teardown must not be able to replace the body's exception with one of
  # its own. `stop_test_agents/0` reads the test's visible spaces
  # (`visible_space_ids/1` → `Repo.all/1`), and a connection that is already
  # gone makes that raise — so on this path a bare `stop_test_agents()` could
  # swap the body's real failure for a teardown error. Say the teardown failure
  # instead, and return an empty report so `log_teardown_failure/1` has nothing
  # further to add.
  defp safe_stop_test_agents do
    stop_test_agents()
  catch
    kind, error ->
      Logger.error(
        "test teardown raised (#{inspect(kind)}: #{inspect(error)}) — the body's " <>
          "failure is being re-raised unchanged"
      )

      %{owned: 0, in_flight: [], not_stopped: []}
  end

  # The body's exception is the one that is raised (see
  # `reraise_after_teardown/3`), so a teardown that also failed can only be
  # *said*, not attached. Say it loudly: a test that left an agent unstopped
  # leaks it into the rest of the run, and that is worth a line in the failure
  # output even when it is not the headline.
  defp log_teardown_failure(%{not_stopped: [], in_flight: []}), do: :ok

  defp log_teardown_failure(%{not_stopped: not_stopped, in_flight: in_flight}) do
    Logger.error(
      "test teardown did not reach zero remaining agents (not stopped: " <>
        "#{inspect(not_stopped)}; in flight: #{inspect(in_flight)}) — the body's " <>
        "failure is being re-raised unchanged"
    )
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
  #     process that will not stop is reported by `not_stopped` instead, which
  #     says what is actually wrong with it.
  defp agent_status(pid) do
    ClientAPI.get_status(pid, @answer_ms)
  catch
    :exit, _reason -> nil
  end

  # Stop one agent and wait for it to die. Returns `:timeout` — never `:ok` —
  # when the `:DOWN` did not arrive inside `timeout`.
  #
  # The wait is the test's idle detector: a test may not complete until its
  # agent is *already* idle, and that is a mandatory invariant, so the stop has
  # to say when it does not hold rather than give up. That is also what makes
  # the bound tight. An agent traps exits, so `Process.exit(pid, :shutdown)`
  # does not kill it — it arrives as the message `{:EXIT, test_pid, :shutdown}`,
  # which `Agent.Handlers.ExitHandler` turns into `{:stop, reason, state}`, and
  # **a message is only handled when the agent reaches its receive loop**. A
  # compliant test's agent is parked there when the test ends, so the handshake
  # is the microseconds it takes to hand the signal over; a test that ended
  # with its agent still working does not get that, and the bound turns the
  # difference into a failure that names the agent instead of a cleanup that
  # quietly reports success. `Agent.terminate/2` keeps no cross-process or
  # filesystem work of its own (see its comments) for exactly that reason: the
  # handshake measures the loop, not the teardown.
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
  # [:flush]` on timeout cleans up any pending DOWN and reports `:timeout`.
  # Deliberately no `:kill`: it skips `terminate/2` and leaks the agent's tmp
  # directory, so an agent that will not stop is reported, not forced.
  defp await_down(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end

  defp raise_not_stopped(not_stopped, timeout) do
    raise "agent did not stop within #{timeout} ms of :shutdown: " <>
            "#{inspect(not_stopped)}"
  end
end
