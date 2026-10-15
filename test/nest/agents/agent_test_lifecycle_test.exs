defmodule Nest.Agents.AgentTestLifecycleTest do
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.AgentTestLifecycle
  alias Nest.Agents.AgentTurnTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

  describe "stop_test_agents/0" do
    test "reports an agent that is still mid-turn as in flight" do
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()

      # A real turn, parked in its HTTP worker: the machine is `:streaming` and
      # stays there because the worker is not released until the end of the
      # test, so the agent is genuinely mid-turn when the teardown runs.
      AgentTurnTestHelpers.park_llm_requests(pid)
      :ok = Agent.chat(pid, "start a turn")
      {_messages, worker} = AgentTurnTestHelpers.next_request()
      ref = Process.monitor(worker)

      result = AgentTestLifecycle.stop_test_agents()

      # The status comes from the agent's own machine, and a turn in flight is
      # reported as such — the guard's whole reason for existing.
      assert [{^space_id, ^name, :streaming}] = result.in_flight

      assert_raise RuntimeError, ~r/still in flight at test finish/, fn ->
        AgentTestLifecycle.assert_zero_remaining!(result)
      end

      # A turn runs in a worker task, not in the agent's loop, so a mid-turn
      # agent *is* parked and its stop is an ordinary handshake. That is the
      # division of labour: `in_flight` catches a turn in progress, and the
      # stop bound (below) catches a loop that is not parked at all.
      assert result.not_stopped == []

      # Reporting a turn in flight is not a cleanup decision: the agent is
      # stopped either way, and the turn's worker is stopped with it
      # (`Agent.stop_turn_workers/1`), so it cannot run any more of the turn
      # after the agent — and the test — are gone. This test used to release the
      # parked worker by hand for exactly that reason.
      refute Process.alive?(pid)
      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}, 1_000
    end

    test "stops the turn's tool worker, so the turn's own DB work dies with the agent" do
      # The isolation defect's shape. A turn's *tool* worker is a Task under the
      # application-wide `Nest.Agents.TaskSupervisor`, so nothing in
      # `Agent.terminate/2` used to reach it — and its DB work is not the
      # agent's: `agents-send` reaches `Agents.send_message/5` →
      # `Supervisor.get_agent/2`'s on-demand load → `Init.LoadHeal.heal/2`, which
      # *appends* in the worker's own DB context. A worker left running past the
      # test process appends on the test's checked-in sandbox connection
      # (`DBConnection.ConnectionError: owner … exited`), after the teardown has
      # stopped every agent it can see. `park_agent_sends/2` holds the worker
      # exactly there: before its `send_message/4`, with the turn still
      # `:executing_tools`.
      {pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: AgentTestHelpers.programmer_vocation_id_for_test()
        })

      space_id = AgentTestHelpers.current_space_id()

      AgentTurnTestHelpers.park_llm_requests(pid)
      AgentTurnTestHelpers.park_agent_sends(pid)

      MockClient.set_tool_response(%{
        text: "Sending",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "note"}
          }
        ]
      })

      MockClient.set_response("After the note")
      :ok = Agent.chat(pid, "start the turn")

      {_request, llm} = AgentTurnTestHelpers.next_request()
      AgentTurnTestHelpers.release_llm(llm)

      assert_receive {:send_blocked, worker}, 1_000
      assert Agent.get_public_info(pid, 1_000).status == :executing_tools
      ref = Process.monitor(worker)

      result = AgentTestLifecycle.stop_test_agents()

      # The turn in flight is reported — this body ended one — so the
      # zero-remaining assertion is not the one under test here; what is under
      # test is that the stop reached the worker.
      assert [{^space_id, ^name, :executing_tools}] = result.in_flight
      assert result.not_stopped == []
      refute Process.alive?(pid)
      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}, 1_000
    end

    test "does not report an agent the test body already stopped as in flight" do
      # The reported shape (`supervisor_persistence_test.exs:66`): the body
      # stops its own agent and discards the result, so the teardown's status
      # question can land while that agent is in `terminate/2`. A stopped agent
      # is not an agent with a turn in flight. Deliberately *not* linked to the
      # test pid (`Supervisor.get_agent/2`, as that test does), so the agent's
      # `:shutdown` cannot reach the test process.
      name = "stopped-by-body-#{System.unique_integer([:positive])}"
      {:ok, space_id} = AgentTestHelpers.create_test_space()

      {:ok, _row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: %{name: "qwen3.5-plus"},
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        })

      AgentTestHelpers.ensure_cleanup(name)

      {:ok, pid} = Supervisor.get_agent(space_id, name)

      # The `:DOWN` is the fence for "it really is gone", and it is needed
      # rather than decorative. `stop_agent/2` fires an exit signal and returns,
      # and the teardown discovers agents through the registry — which this
      # agent empties inside `terminate/2`, before it dies — so an agent already
      # past that point when the teardown looks is invisible to it, nothing
      # waits for its death, and a bare aliveness read is a race rather than a
      # fact.
      ref = Process.monitor(pid)
      :ok = Supervisor.stop_agent(space_id, name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500

      result = AgentTestLifecycle.stop_test_agents()

      assert result.in_flight == []
      assert result.not_stopped == []
      assert :ok = AgentTestLifecycle.assert_zero_remaining!(result)
      refute Process.alive?(pid)
    end

    test "reports an agent that does not stop, naming it" do
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()

      # The stop bound's target, without racing a real turn: a suspended agent
      # never reaches its receive loop, so it never handles the `{:EXIT, ...}`
      # `Process.exit/2` delivers and never dies. That is what a test that ends
      # with its agent still working looks like from here.
      #
      # This also pins the answer-wait blind spot: a status read that does not
      # answer inside `@answer_ms` is **not** reported as in flight, because a
      # non-answer is not a status. A process that will not stop is reported
      # instead — which says what is actually wrong with it.
      :ok = :sys.suspend(pid)

      result = AgentTestLifecycle.stop_test_agents()

      assert result.in_flight == []
      assert result.not_stopped == [{space_id, name}]

      assert_raise RuntimeError, ~r/did not stop within 150 ms of :shutdown/, fn ->
        AgentTestLifecycle.assert_zero_remaining!(result)
      end

      # The same detector in its other entry point, and both name the agent. The
      # timeout is incidental to what this line pins (that the message names the
      # agent), so it is short — the bound itself is pinned by the line above.
      assert_raise RuntimeError, ~r/#{name}/, fn ->
        AgentTestLifecycle.wait_for_pid_down(space_id, name, 25)
      end

      # The stop does not kill: the agent is still there, which is the point of
      # reporting rather than forcing. Release it so the wrapped teardown below
      # sees it stop normally instead of failing this test a second time.
      assert Process.alive?(pid)
      :ok = :sys.resume(pid)
    end

    test "does not report a registered process that never answers as in flight" do
      {:ok, space_id} = AgentTestHelpers.create_test_space()
      name = "never-answers-#{System.unique_integer([:positive])}"
      test_pid = self()

      # A process registered in the agents Registry that never answers: the
      # teardown cannot learn a status from it. "Cannot answer" must not read
      # as "in flight" — that reading is what failed a test whose body had
      # already stopped its agent, leaving it unresponsive in `terminate/2`.
      pid =
        spawn(fn ->
          {:ok, _} = Elixir.Registry.register(Nest.Agents.Registry, {space_id, name}, nil)
          send(test_pid, {:registered, self()})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:registered, ^pid}

      result = AgentTestLifecycle.stop_test_agents()

      assert result.in_flight == []
      assert :ok = AgentTestLifecycle.assert_zero_remaining!(result)
      # Not in flight is not the same as unaccounted for: it does not trap
      # exits, so the `:shutdown` signal kills it, and the `not_stopped` half
      # of the guard would report it if it did not.
      refute Process.alive?(pid)
      assert result.not_stopped == []
    end

    test "does not report an idle agent whose teardown is slow" do
      # The regression this guard was fixed for. `Agent.terminate/2` ends with
      # `cleanup_tmp/2` -> `TmpSpace.cleanup/2` -> `File.rm_rf/1`, so the stop
      # handshake contains real filesystem work — a `File.rm_rf` per agent — and
      # it is not a measurement of the agent's receive loop. The bound used to be
      # 10 ms, and that handshake reaches it on a busy machine — 12 provably idle
      # agents (every one of them answering `:idle`) took a tight 8.5-9.1 ms
      # under 32 CPU burners, and crossed 10 ms as soon as anything else loaded
      # the host — failing tests whose agents were not in flight at all.
      #
      # A populated scratch directory is a *real* teardown load rather than a
      # stub: it is the same `File.rm_rf` the agent runs for itself, and the
      # teardown's cost is the number of file operations in it. Deliberately
      # small — `File.rm_rf` of 100 entries measures 332-597 ms under 32 CPU
      # burners, so a pin big enough to be a *magnitude* check would itself go
      # flaky on a loaded host, and a sometimes-failing test is worse than a
      # failing one. Its margin depends on which measurement you take: file-alone,
      # a 20-entry handshake is 3.96 ms on the slow host, so it clears the bound by
      # ~38x; under full suite load the worst handshake measured is 39.3 ms, ~3.8x.
      # What this pins is the contract: a populated scratch directory must not turn
      # an idle agent into a violation. The bound's floor,
      # which is what a tightening would break, is pinned separately and
      # deterministically below.
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()

      scratch = TmpSpace.create(space_id, name)
      Enum.each(1..20, fn i -> File.write!(Path.join(scratch, "f#{i}"), "x") end)

      result = AgentTestLifecycle.stop_test_agents()

      # Asserted through the gate rather than on the raw lists, so a failure
      # carries the diag: how long the stop actually took and what the agent was
      # doing when it missed the bound.
      assert result.in_flight == []
      assert :ok = AgentTestLifecycle.assert_zero_remaining!(result)
      refute Process.alive?(pid)
    end

    test "the stop bound stays wide enough to clear a real teardown" do
      # The bound is a liveness bound and has to keep clearing the handshake,
      # which contains `terminate/2`'s `File.rm_rf`. Measured: 25-110 us with an
      # idle host, a flat 8.5-9.1 ms plateau under CPU saturation, and 332-597 ms
      # for a 100-entry scratch
      # directory under the same load. Tightening this back toward the
      # handshake is the bug this guard was fixed for, so the floor is pinned
      # rather than left to a comment.
      assert AgentTestLifecycle.stop_bound_ms() >= 150
    end
  end

  describe "the per-test on_exit hooks" do
    test "are registered, and each issues no query" do
      {pid, name} = AgentTestHelpers.start_agent()
      space_id = AgentTestHelpers.current_space_id()
      test_pid = self()

      # The leak check waits out `cleanup_ms` for a live agent, so stop it first:
      # both hooks then take their fast path, and the query-free property is what
      # is under test here, not the wait. The stop runs in the body, while the
      # sandbox connection is still checked out.
      Process.unlink(pid)
      :ok = Supervisor.stop_agent(space_id, name)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      # The callbacks invoked below are the ones `register_on_exit_cleanup/3`
      # actually registered — read back from ExUnit by their keys — not
      # lookalikes, so a stop re-added to either closure's body is exercised by
      # this test instead of escaping it.
      cleanup = registered_on_exit(AgentTestHelpers.cleanup_key(space_id, name))
      leak = registered_on_exit(AgentTestHelpers.leak_key(space_id, name))
      refute is_nil(cleanup)
      refute is_nil(leak)

      # A plain `spawn` inherits no `$callers`, so it has no sandbox connection:
      # a query in a hook would crash it with `DBConnection.OwnershipError`
      # instead of reporting. The real `on_exit` runs in exactly such a process —
      # after the test pid, the connection owner, has exited — which is why a
      # hook must not stop the agent (`Supervisor.stop_agent/2` runs
      # `terminate/2`, and that queries).
      runner =
        spawn(fn ->
          send(test_pid, {:hooks, cleanup.(), leak.()})
        end)

      ref = Process.monitor(runner)

      assert_receive {:hooks, :ok, :ok}, 1_000
      # `:normal`, not a crash: a query in either hook would have killed the
      # process with `DBConnection.OwnershipError` before it could report.
      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 1_000
    end
  end

  describe "detect_leaked_agent/2" do
    test "reports an agent that has not gone away, and not one that has" do
      {:ok, space_id} = AgentTestHelpers.create_test_space()
      name = "leaked-#{System.unique_integer([:positive])}"
      test_pid = self()

      # A process registered in the agents Registry that stays up: the shape of
      # an agent the per-test teardown never reached (a test killed at its
      # deadline skips the wrapper). The short bound is this test's own — the
      # production default is `cleanup_ms/0`.
      pid =
        spawn(fn ->
          {:ok, _} = Elixir.Registry.register(Nest.Agents.Registry, {space_id, name}, nil)
          send(test_pid, {:registered, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, ^pid}

      log =
        capture_log(fn ->
          assert AgentTestLifecycle.detect_leaked_agent(space_id, name, 10) ==
                   {:leaked, space_id, name}
        end)

      # The report is the observable an operator sees; the return value above is
      # the machine-readable half.
      assert log =~ "is still alive after its test"
      assert log =~ name

      # Once it is gone, the detector does not report it.
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert AgentTestLifecycle.detect_leaked_agent(space_id, name, 10) == :ok
    end
  end

  describe "reraise_after_teardown/3" do
    test "re-raises every failure kind with the original stacktrace" do
      # A stacktrace that cannot have come from the re-raise site, so the
      # assertion can tell "re-raised with the caller's trace" apart from
      # "raised anew here".
      stacktrace = [{__MODULE__, :probe, 0, [file: ~c"probe.ex", line: 7]}]

      try do
        AgentTestLifecycle.reraise_after_teardown(
          :error,
          RuntimeError.exception("boom"),
          stacktrace
        )
      rescue
        error ->
          assert Exception.message(error) == "boom"
          # The re-raise must carry the caller's frame, not its own.
          assert [{__MODULE__, :probe, 0, _} | _] = __STACKTRACE__
      end

      # `reraise/2` only handles `:error`; the wrapped test bodies can fail
      # with `:throw`/`:exit` too, so this must carry those through as well.
      assert catch_throw(AgentTestLifecycle.reraise_after_teardown(:throw, :ball, stacktrace)) ==
               :ball

      assert catch_exit(AgentTestLifecycle.reraise_after_teardown(:exit, :boom, stacktrace)) ==
               :boom
    end

    test "keeps the body's exception when the teardown also fails" do
      # The trap: a hard-failing teardown must not replace an already-failing
      # test's exception. An agent suspended past the stop bound makes the
      # teardown fail; the body's `RuntimeError` is still the one raised, with
      # its own stacktrace. The teardown's own failure cannot be attached to
      # that exception without changing it, so it is *said* — the log line is
      # the observable for it.
      {pid, name} = AgentTestHelpers.start_agent()
      :ok = :sys.suspend(pid)

      stacktrace = [{__MODULE__, :probe, 0, [file: ~c"probe.ex", line: 7]}]

      log =
        capture_log(fn ->
          try do
            AgentTestLifecycle.reraise_after_teardown(
              :error,
              RuntimeError.exception("body boom"),
              stacktrace
            )
          rescue
            error ->
              assert Exception.message(error) == "body boom"
              assert [{__MODULE__, :probe, 0, _} | _] = __STACKTRACE__
          end
        end)

      assert log =~ "did not reach zero remaining agents"
      assert log =~ name

      :ok = :sys.resume(pid)
    end
  end

  # The `on_exit` callback this test registered under `key`, as ExUnit stores
  # it, or `nil`. `ExUnit.Server` is ExUnit's own public ETS table of on_exit
  # callbacks, keyed by the test pid; reading it is how a test asserts that a
  # hook is registered, rather than only exercising the function the hook calls.
  defp registered_on_exit(key) do
    :ets.lookup_element(ExUnit.Server, self(), 3)
    |> Enum.find_value(fn
      {^key, callback} -> callback
      _ -> nil
    end)
  end
end
