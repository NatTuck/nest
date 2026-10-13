defmodule Nest.Agents.AgentTestLifecycleTest do
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.AgentTestLifecycle
  alias Nest.Agents.AgentTurnTestHelpers
  alias Nest.Agents.Supervisor

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

      result = AgentTestLifecycle.stop_test_agents()

      # The status comes from the agent's own machine, and a turn in flight is
      # reported as such — the guard's whole reason for existing.
      assert [{^space_id, ^name, :streaming}] = result.in_flight

      assert_raise RuntimeError, ~r/still in flight at test finish/, fn ->
        AgentTestLifecycle.assert_zero_remaining!(result)
      end

      # Reporting a turn in flight is not a cleanup decision: the agent is
      # stopped either way, and the parked worker is released so it cannot
      # outlive the test.
      refute Process.alive?(pid)
      AgentTurnTestHelpers.release_llm(worker)
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
      :ok = Supervisor.stop_agent(space_id, name)

      result = AgentTestLifecycle.stop_test_agents()

      assert result.in_flight == []
      assert result.still_alive == []
      assert :ok = AgentTestLifecycle.assert_zero_remaining!(result)
      refute Process.alive?(pid)
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
      # Not in flight is not the same as unaccounted for: it is stopped, and
      # the `still_alive` half of the guard would report it if it were not.
      refute Process.alive?(pid)
      assert result.still_alive == []
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
  end
end
