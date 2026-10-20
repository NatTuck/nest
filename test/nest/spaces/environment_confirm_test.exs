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

  import Eventually
  import Mimic

  import Nest.Agents.AgentTurnTestHelpers

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.SpaceGate
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.Paths
  alias Nest.Sandbox.ShellJobs
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
    Phoenix.PubSub.subscribe(Nest.PubSub, SpaceGate.topic(space_id))

    # A start reads the row for the space's three environment values, so it must
    # not run while an edit is writing them. The name has no row, so this would
    # answer `:not_found` at once — unless the gate is ahead of the read.
    #
    # The barrier is the gate's own frame: `await/2` broadcasts
    # `{:space_waiting, _}` once it is still held after subscribing and
    # immediately before it blocks, so receiving it proves the start is parked at
    # the gate. A bypassed gate sends no frame at all, and the `:not_found` below
    # can only be answered after the release — the block is what `await/2` returns
    # from. (A 50 ms probe here used to say only "not yet".)
    starter = Task.async(fn -> Supervisor.get_agent(space_id, "not-an-agent") end)

    assert_receive {:space_waiting, ^space_id}, 1_000

    assert :ok = SpaceGate.release(space_id)
    assert {:error, :not_found} = Task.await(starter, 1_000)
  end

  # The spawn paths do not go through `fetch_or_start_agent/2`, so the latch has
  # to be taken by the spawn itself: it reads the space's workspace from the row
  # and starts a process from it, and a child that started in the window would be
  # new — no cast reaches it and no mark exists for it yet.
  test "a spawn waits for the latch before it reads the row" do
    {pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()
    # allowlist: harness — spawn_agent_in_space/3's state argument
    parent = :sys.get_state(pid, 1_000)
    child = "child-#{System.unique_integer([:positive])}"

    assert :ok = SpaceGate.hold(space_id)
    Phoenix.PubSub.subscribe(Nest.PubSub, SpaceGate.topic(space_id))

    # The same barrier as the start test: the spawn's own `await/2` broadcasts
    # `{:space_waiting, _}` from inside the call, before it blocks — so the missing
    # row below is the gate's doing rather than the scheduler's, and a bypassed
    # gate sends no frame.
    spawner =
      Task.async(fn ->
        Supervisor.spawn_agent_in_space(parent, child, AgentTestHelpers.vocation_slug_for_test())
      end)

    assert_receive {:space_waiting, ^space_id}, 1_000
    assert Nest.Persistence.fetch_agent(space_id, child) == {:error, :not_found}

    assert :ok = SpaceGate.release(space_id)
    assert {:ok, ^child} = Task.await(spawner, 2_000)
    AgentTestHelpers.ensure_cleanup(child)
  end

  # A turn that arrives while the space is paused is **queued**, not refused and
  # not blocked: the agent process must never wait on the latch. The unlock is the
  # wake-up, and it drains through the turn boundary's own path.
  test "a turn that arrives while the space is paused is queued, and the unlock runs it" do
    {pid, name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    assert :ok = SpaceGate.hold(space_id)

    assert :ok = Agents.chat(space_id, name, "hi", nil, "tester", true)

    # Queued, not running: a turn that had started would have taken the message
    # out of the queue. `get_public_info/2` is a call, so it is also the fence
    # behind the cast above.
    assert [%{"content" => "hi"}] = Agent.get_public_info(pid, 1_000).pending_messages

    # The unlock drains it: the turn runs, and the queue empties.
    assert :ok = SpaceGate.release(space_id)

    eventually(fn -> length(Persistence.load_messages(space_id, name)) > 1 end)
    eventually(fn -> Agent.get_public_info(pid, 1_000).pending_messages == [] end)
    # Both waits above are satisfied the moment the turn *starts*, and
    # `AgentTestLifecycle` refuses a test that leaves an owned agent in flight, so
    # the turn has to be seen to finish before the body returns.
    eventually(fn -> Agent.get_public_info(pid, 1_000).status == :idle end)
  end

  # The unlock's drain is `Turn.drain_inbox/1`, the single drain path, so it keeps
  # that path's mode bookkeeping: a queued message's mode is *written down* when it
  # is delivered (`keep_mode/2`). A hand-rolled peek-then-settle would apply the
  # mode in memory and never persist it, and a restart would put the agent back in
  # the mode the row still holds.
  test "the unlock's drain writes down the mode a queued message asked for" do
    {pid, name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    assert :ok = SpaceGate.hold(space_id)
    assert :ok = Agents.chat(space_id, name, "hi", "plan", "tester", true)

    assert :ok = SpaceGate.release(space_id)

    eventually(fn -> Agent.get_public_info(pid, 1_000).current_mode == "plan" end)
    assert {:ok, %{mode: "plan"}} = Persistence.fetch_agent(space_id, name)
    eventually(fn -> Agent.get_public_info(pid, 1_000).status == :idle end)
  end

  # The plan has to count a job that is really running: the confirmation is what
  # tells the user a background job is about to be stopped.
  test "the plan counts a real background job" do
    {pid, name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()
    # allowlist: snapshot — the agent's own mounts, which the job needs.
    state = :sys.get_state(pid, 1_000)

    start_job(space_id, name, pid, state.mounts)

    assert {:error, {:confirmation_required, plan}} =
             Spaces.update_environment(space_id, %{network_access: false})

    assert plan.jobs == 1
    assert :ok = SpaceGate.release(space_id)
  end

  # A real background job for `{space_id, name}`, staged the way `ShellCmd` stages
  # one: the job's command line is the backend's to build from a staged script.
  defp start_job(space_id, name, pid, mounts) do
    key = {space_id, name}
    scratch = Mounts.scratch(mounts)
    dir = Paths.stage_dir(scratch)
    File.mkdir_p!(dir)
    script = Path.join(dir, "run.sh")
    File.write!(script, "sleep 30\n")

    {:ok, _id, _log} =
      ShellJobs.start_job(%{
        agent_key: key,
        agent_pid: pid,
        command: "sleep 30",
        # The staged *file's* two spellings: the sandbox one is what the backend's
        # command line runs, the host one is what gets cleaned up. Handing over the
        # stage *directory* (as this did) launched `bash <dir>`, which exits 126 at
        # once — invisible to a test that only counted the job, fatal to one that
        # looks at its status later.
        script_sandbox: Path.join(Paths.stage_dir_sandbox(scratch), "run.sh"),
        script_path: script,
        mounts: mounts,
        max_jobs: 100
      })

    on_exit(fn -> ShellJobs.stop_all(key) end)
    :ok
  end

  # The plan the user confirms says what the edit *will* stop. A save that never
  # happens must therefore stop nothing — not a tool call, not a background job,
  # and not even the latch.
  test "a save the sandbox refuses stops nothing" do
    {pid, name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()
    # allowlist: snapshot — the agent's own mounts, which the job needs.
    state = :sys.get_state(pid, 1_000)
    start_job(space_id, name, pid, state.mounts)
    workspace = Spaces.get_space(space_id).workspace_path

    # Confirmed, so the plan is not the question: the refusal is.
    assert {:error, :workspace_missing} =
             Spaces.update_environment(
               space_id,
               %{workspace_path: "/nonexistent/nest-ws"},
               confirm: true
             )

    assert [%{status: :running}] = ShellJobs.list({space_id, name})
    assert Spaces.get_space(space_id).workspace_path == workspace
    # The refusal came before the latch, so the space was never even paused.
    refute SpaceGate.held?(space_id)
  end

  test "a blank workspace is refused rather than saved as a no-op" do
    {_pid, _name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()

    Phoenix.PubSub.subscribe(Nest.PubSub, SpaceGate.topic(space_id))

    # `""` casts to no change *and* fails `validate_required`, so this is the shape
    # that has no changes at all: it must be an error, never `{:ok, old_row}`.
    assert {:error, %Ecto.Changeset{errors: errors}} =
             Spaces.update_environment(space_id, %{workspace_path: ""})

    assert Keyword.has_key?(errors, :workspace_path)

    # Never paused, and `held?/1` cannot say so: the refusal happens before the
    # latch, but the edit's own `after` releases it either way, so `held?` reads
    # `false` whether or not it was ever taken. The frame `hold/3` broadcasts
    # before it returns is the observable.
    refute_receive {:space_locked, ^space_id}, 0
  end

  test "a save that names what the row already says stops nothing" do
    {pid, name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()
    # allowlist: snapshot — the agent's own mounts, which the job needs.
    state = :sys.get_state(pid, 1_000)
    start_job(space_id, name, pid, state.mounts)

    # No confirmation, and none needed: there is nothing to write, so there is
    # nothing to stop and nothing to ask about.
    assert {:ok, %Spaces.Space{}} =
             Spaces.update_environment(space_id, %{
               workspace_path: Spaces.get_space(space_id).workspace_path,
               network_access: Spaces.get_space(space_id).network_access,
               sandbox_backend: Spaces.get_space(space_id).sandbox_backend
             })

    assert [%{status: :running}] = ShellJobs.list({space_id, name})
    refute SpaceGate.held?(space_id)
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
