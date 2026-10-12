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
      registration is required.
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

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Registry
  alias Nest.Repo
  alias Nest.Spaces.Space

  # Observable status values that mean an LLM/tool/compaction turn is
  # actively running. Every other value (`:idle`, `:model_missing`,
  # `:context_overflow`, `:compaction_failed`,
  # `:compaction_loop_detected`) is a terminal/frozen state where no
  # turn is in flight, so the agent cannot write to the DB anymore.
  @in_flight_statuses [:streaming, :executing_tools, :compacting, :unresponsive]

  # The teardown probe's bound is a *measurement*, not a failure bound, and it is
  # the single documented exception to the 1000 ms the ruling sets for fences: it
  # goes DOWN, not up. An idle agent answers `:sys.get_state/2` in microseconds, so
  # the bound costs nothing on the happy path — but `stop_test_agents/0` probes
  # every owned agent synchronously, so a long bound makes teardown cost N x bound
  # and blows the per-test deadline. That is the bug this replaces (500 ms x N).
  #
  # Sizing, honestly: a synthetic saturation probe was not usable. 32 yield-loops,
  # and then 16 blocked + 16 allocating workers, both starved a *parked* process
  # past a 5 s bound, so neither shape is the suite's and neither can size this.
  # 250 ms is therefore chosen for what the bound is FOR, not from a distribution:
  # it caps teardown at 250 ms per agent that cannot answer, and an agent that
  # cannot answer in 250 ms while idle is either wedged or mid-turn — the two cases
  # this check exists to catch. A starved-but-healthy agent now reads as in flight
  # and fails the test; that is the intended direction (see `agent_status/1`) and is
  # recorded in `notes/sketchy-slow-tests.md`.
  #
  # Follow-up: log the real probe-latency distribution from a suite run (16-way)
  # and revisit this number with data. Do NOT "fix" it to 1000.
  @agent_probe_ms 250

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
  def wait_for_pid_down(space_id, name, timeout \\ 2_000) do
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
  [...]}`. Stop + single `:DOWN` wait, no loops. The caller decides
  whether to raise so that cleanup cannot mask an unrelated body
  failure.
  """
  @spec stop_test_agents() :: map()
  def stop_test_agents do
    owned = owned_agents()

    in_flight =
      for {space_id, name, pid} <- owned,
          status = agent_status(pid),
          status in @in_flight_statuses do
        {space_id, name, status}
      end

    Enum.each(owned, fn {_space_id, _name, pid} -> stop_pid(pid) end)

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

  # Synchronous, loop-free read of the agent's live status, with the in-flight
  # signal **inverted**: an agent that does not answer is busy, which is exactly
  # what "in flight" means. Three outcomes, distinguished by the exit reason:
  #
  #   * answers with a state      -> its status (`Machine.status_for/1`);
  #   * answers with anything else -> `:not_an_agent` (a unit test registered a
  #     stand-in in the agents Registry; that must NOT read as in-flight);
  #   * dead pid (`:noproc`)       -> `nil` — down, not in flight (already
  #     reported by `still_alive`);
  #   * alive but did not answer   -> `:unresponsive` — in flight.
  #
  # The last one is a deliberate behaviour change: a starved-but-healthy agent now
  # *fails* the test instead of passing silently, because the old `:exit, _ -> nil`
  # made the check miss precisely the case it exists to detect ("the test finished
  # while a turn was still running"). Recorded in `notes/sketchy-slow-tests.md`.
  defp agent_status(pid) do
    case :sys.get_state(pid, @agent_probe_ms) do
      %{live: %{machine: machine}} -> Machine.status_for(machine)
      _ -> :not_an_agent
    end
  catch
    :exit, reason -> if agent_gone?(reason), do: nil, else: :unresponsive
  end

  # `:sys.get_state/2` exits with the bare atom `:timeout` when the process does
  # not answer in time; a pid that is already dead gives `:noproc`.
  defp agent_gone?(:noproc), do: true
  defp agent_gone?(:normal), do: true
  defp agent_gone?(:shutdown), do: true
  defp agent_gone?({:noproc, _}), do: true
  defp agent_gone?({:normal, _}), do: true
  defp agent_gone?({:shutdown, _}), do: true
  defp agent_gone?(_), do: false

  defp stop_pid(pid, timeout \\ 2_000) do
    # Unlink first: test-started agents are linked to the test pid so
    # an unexpected crash fails the test. A deliberate `:shutdown`
    # would otherwise propagate to (and kill) the test pid.
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end
end
