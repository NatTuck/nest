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
    * `teardown_agents!/0` — the in-process teardown that runs before
      the test process (the sandbox connection owner) exits. It
      *discovers* every agent belonging to the current test via the
      global `Nest.Agents.Registry` (every agent registers itself in
      `Agent.start_link/1`, including production-spawned children and
      `start_supervised!` pids), scoped to the spaces the test created
      (visible in the test's sandbox transaction). No per-test
      registration is required.

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

  alias Nest.Agents.Registry
  alias Nest.Repo
  alias Nest.Spaces.Space

  # `live.status` values that mean an LLM/tool/compaction turn is
  # actively running. Every other value (`:idle`, `:model_missing`,
  # `:context_overflow`, `:compaction_failed`,
  # `:compaction_loop_detected`) is a terminal/frozen state where no
  # turn is in flight, so the agent cannot write to the DB anymore.
  @in_flight_statuses [:streaming, :executing_tools, :compacting]

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
  def wait_for_pid_down(space_id, name, timeout \\ 5_000) do
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
  (`live.status` in `[:streaming, :executing_tools, :compacting]`) when
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

  # Every agent the current test owns: registered live agents whose
  # space was created inside this test's sandbox transaction.
  @spec owned_agents() :: list({integer(), String.t(), pid()})
  def owned_agents do
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

  # Synchronous, loop-free read of the agent's live status. A pid
  # that died between listing and reading is treated as down (`nil`),
  # and a non-Agent process registered in the agents Registry (some
  # unit tests register a fake parent) is treated as not-in-flight.
  defp agent_status(pid) do
    case :sys.get_state(pid) do
      %{live: %{status: status}} -> status
      _ -> :not_an_agent
    end
  catch
    :exit, _ -> nil
  end

  defp stop_pid(pid, timeout \\ 5_000) do
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
