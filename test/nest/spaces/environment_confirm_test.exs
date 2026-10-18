defmodule Nest.Spaces.EnvironmentConfirmTest do
  @moduledoc """
  The space edit's two phases, and the latch that makes them safe.

  An edit that would stop work needs the user's word first, so
  `Nest.Spaces.update_environment/2` answers `{:confirmation_required, plan}`
  instead of writing the row when anything is running. The space's
  `Nest.Agents.SpaceGate` latch is taken *before* the plan is read and is held
  while the user decides, which is what makes the plan exact — nothing can start
  in the space, so the set it names cannot grow — and what makes cancelling free:
  the latch comes down and everything proceeds.
  """

  use Nest.DataCase, async: true

  import Mimic

  import Nest.Agents.AgentTurnTestHelpers

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.SpaceGate
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Spaces

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    :ok
  end

  # An agent with a turn in flight: the parked request is what holds it in
  # `:streaming` without a timer.
  defp working_agent do
    {pid, name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    park_next_llm_request(pid)
    :ok = Agents.chat(space_id, name, "hi", nil, "tester", true)
    {_messages, worker} = next_request()

    {space_id, name, worker}
  end

  test "a working agent needs the user's word, and the space stays paused meanwhile" do
    {space_id, name, worker} = working_agent()

    assert {:error, {:confirmation_required, plan}} =
             Spaces.update_environment(space_id, %{network_access: false})

    assert [%{name: ^name, status: :streaming, jobs: 0}] = plan.agents
    assert plan.jobs == 0

    # Nothing was written, and nothing can start: the latch is up.
    assert Spaces.get_space(space_id).network_access == true
    assert SpaceGate.held?(space_id)

    release_llm(worker)
    assert List.last(statuses_until_idle(name)) == "idle"
  end

  test "cancelling releases the space and changes nothing" do
    {space_id, name, worker} = working_agent()

    assert {:error, {:confirmation_required, _plan}} =
             Spaces.update_environment(space_id, %{network_access: false})

    # The client's "no": the latch comes down, the turn keeps running.
    assert :ok = SpaceGate.release(space_id)
    refute SpaceGate.held?(space_id)
    assert Spaces.get_space(space_id).network_access == true

    release_llm(worker)
    assert List.last(statuses_until_idle(name)) == "idle"
  end

  test "confirming writes the row and releases the space" do
    {space_id, name, worker} = working_agent()

    assert {:error, {:confirmation_required, _plan}} =
             Spaces.update_environment(space_id, %{network_access: false})

    assert {:ok, %Spaces.Space{network_access: false}} =
             Spaces.update_environment(space_id, %{network_access: false}, confirm: true)

    refute SpaceGate.held?(space_id)

    release_llm(worker)
    assert List.last(statuses_until_idle(name)) == "idle"
  end

  test "a quiet space is edited without a prompt" do
    {_pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    assert {:ok, %Spaces.Space{network_access: false}} =
             Spaces.update_environment(space_id, %{network_access: false})

    refute SpaceGate.held?(space_id)
  end

  test "a start waits for the latch before it reads the row" do
    {_pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    assert :ok = SpaceGate.hold(space_id)

    # A start reads the row for the space's three environment values, so it must
    # not run while an edit is writing them. The name has no row, so this would
    # answer `:not_found` at once — unless the gate is ahead of the read.
    starter = Task.async(fn -> Supervisor.get_agent(space_id, "not-an-agent") end)
    assert Task.yield(starter, 50) == nil

    assert :ok = SpaceGate.release(space_id)
    assert {:error, :not_found} = Task.await(starter, 1_000)
  end

  test "a second session is refused while the first is deciding" do
    {_pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    # Another channel holding the space is the state under test.
    assert :ok = SpaceGate.hold(space_id)

    assert {:error, :space_changing} =
             Task.async(fn ->
               Spaces.update_environment(space_id, %{network_access: false})
             end)
             |> Task.await()

    assert Spaces.get_space(space_id).network_access == true

    assert :ok = SpaceGate.release(space_id)
  end
end
