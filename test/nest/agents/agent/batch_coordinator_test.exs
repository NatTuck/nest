defmodule Nest.Agents.Agent.BatchCoordinatorTest do
  @moduledoc """
  The batch coordinator's own failure paths, driven directly.

  `agents_batch_test.exs` covers the fork-join end to end (through a real
  `agents-batch` tool call); this file covers what the coordinator does when the
  parent it was launched for is not there to run it: its crash report, and the
  delivery of that report finding no inbox. Both are logged rather than raised —
  a batch's failure must not take down the task supervisor or a parent.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.BatchCoordinator
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.LLM.MockClient
  alias Nest.Messages.ToolCall

  import Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  setup do
    # The MockClient queue belongs to the test pid until `start_agent/1`
    # transfers it to the agent.
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "a dead parent is reported, not crashed into" do
    {parent_pid, _name} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: programmer_vocation_id_for_test()
      })

    space_id = current_space_id()
    test_pid = self()

    # The parent the coordinator reports to: forced dead, and *observed* dead
    # before the coordinator starts. (A process spawned to exit immediately can
    # be dead before the monitor is attached, which makes the DOWN reason
    # `:noproc` instead of `:killed` — a race, so the death is forced here.)
    gone =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    gone_ref = Process.monitor(gone)
    Process.exit(gone, :kill)
    assert_receive {:DOWN, ^gone_ref, :process, ^gone, :killed}, 500

    # The plan's *parent* (the name its spawn call goes to) is a registered
    # stand-in that never answers, so the coordinator's first call blocks. That
    # is what makes its lifetime observable without a race: a coordinator that
    # crashes immediately would be gone before a monitor could be attached. Its
    # registration is acknowledged before the coordinator starts, so the call
    # cannot race it either.
    name = "stand-in-#{System.unique_integer([:positive])}"

    stand_in =
      start_supervised!(
        {Task,
         fn ->
           Registry.register(AgentsRegistry, {space_id, name}, nil)
           send(test_pid, {:registered, self()})

           receive do
             :never -> :ok
           end
         end}
      )

    assert_receive {:registered, ^stand_in}, 500

    ctx = %{Turn.build_ctx(:sys.get_state(parent_pid)) | agent_pid: gone, agent_name: name}
    tc = %ToolCall{name: "agents-batch", arguments: %{"items" => ["alpha"]}}

    log =
      capture_log(fn ->
        assert {:ok, confirmation} = BatchCoordinator.run(ctx, tc)
        assert confirmation =~ "Fanned 1 item(s)"

        # This test's coordinator is the task carrying its own unique dead
        # parent in `$callers` (`BatchCoordinator.start/3` puts `ctx.agent_pid`
        # there), so no concurrent test's task can match.
        coordinator = Eventually.eventually(fn -> find_coordinator(gone) end, timeout: 500)
        coordinator_ref = Process.monitor(coordinator)

        # Release the blocked call: it exits, so the coordinator takes its crash
        # path — and the report goes to a parent that is gone.
        Process.exit(stand_in, :kill)
        assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}, 500
      end)

    # The crash path says *why* it stopped, and the delivery says the parent is
    # gone — not that a delivery "could not happen" for an unstated reason.
    assert log =~ "coordinator stopped before the aggregate"
    assert log =~ "the parent is gone; the aggregate was not delivered"

    # Nothing was registered against a parent that does not exist.
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "alpha")
  end

  # The task this test launched: the only one carrying the unique dead parent in
  # `$callers`.
  defp find_coordinator(owner) do
    Enum.find(Task.Supervisor.children(Nest.Agents.TaskSupervisor), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, :"$callers", []) == [owner]
        _other -> false
      end
    end)
  end
end
