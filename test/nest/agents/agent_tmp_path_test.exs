defmodule Nest.Agents.AgentTmpPathTest do
  @moduledoc """
  Agent tmp_path lifecycle tests. `async: true`. The
  `/tmp/nest-VMPID/space-SPACE/NAME/` dirs are per-VM shared
  state, but each test uses a fresh space and a fresh
  `System.unique_integer/1` agent name and asserts on its own
  dir; concurrent tests' dirs sit at their own VMPID+space+name
  path and don't collide.

  IMPORTANT: the shared parent `/tmp/nest-VMPID/` (and the space
  dirs beneath it) must NEVER be wiped (in setup or on_exit). The
  `nest-VMPID` root is process-global across all agents/tests in
  this BEAM. A `File.rm_rf` on it races with a concurrent async
  test's agent that is mid-`shell_cmd`: the wipe deletes that
  agent's tmp dir while bwrap is starting, producing `bwrap: Can't
  find source path` (exit_code=1). Per-agent dirs are unique (via
  `System.unique_integer/1`) and cleaned by their own
  `terminate/2`, so a parent wipe buys nothing and only causes
  this flake. The parent is left in place and cleared by system
  `/tmp` cleanup (see `Nest.Agents.Agent.TmpSpace`).
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    # NOTE: do NOT `File.rm_rf` the shared parent
    # `/tmp/nest-<System.pid()>/` here. It is process-global across
    # all concurrent agents/tests in this BEAM, so wiping it in
    # setup/on_exit races with another async test whose agent is
    # mid-`shell_cmd`, deleting its tmp dir under bwrap and
    # producing the intermittent `bwrap: Can't find source path`
    # error (exit_code=1). Each test below uses a unique space +
    # agent name and cleans up its own dir, so the parent must be
    # left alone.

    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  # The agent's own scratch dir: <space_dir>/<agent-name>, where
  # <space_dir> = /tmp/nest-<VMPID>/space-<space_id>.
  defp agent_tmp_path(space_id, name) do
    Path.join(["/tmp", "nest-#{System.pid()}", "space-#{space_id}", name])
  end

  defp space_dir(space_id) do
    Path.join(["/tmp", "nest-#{System.pid()}", "space-#{space_id}"])
  end

  describe "tmp_path lifecycle" do
    test "creates tmp directory on agent start" do
      {_pid, name} = start_agent()
      expected_tmp_path = agent_tmp_path(current_space_id(), name)

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      assert File.dir?(expected_tmp_path)
    end

    test "passes tmp_path to agent state" do
      {pid, _name} = start_agent()

      # Read the agent's own state rather than the introspection payload:
      # the scratch dir is a real host directory and is deliberately not on
      # the wire (asserted below).
      # allowlist: snapshot — tmp_path
      state = :sys.get_state(pid, 1_000)

      assert state.tmp_path =~ ~r|/tmp/nest-#{System.pid()}/space-\d+/agent\d+|,
             "Expected tmp_path to match pattern, got: #{inspect(state.tmp_path)}"

      # It must not reach a client either. `build_public_info/1` is what the
      # channels push, and #79 removed the field from it so the one remaining
      # host path outside `Nest.Sandbox.Mounts` stops leaving the boundary.
      refute Map.has_key?(Agent.get_public_info(pid), :tmp_path)
    end

    test "cleans up tmp directory on agent termination" do
      {pid, name} = start_agent()
      expected_tmp_path = agent_tmp_path(current_space_id(), name)

      assert File.exists?(expected_tmp_path)

      ref = Process.monitor(pid)
      Agent.terminate(pid)
      wait_for_down(ref, pid, :_)

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed: #{expected_tmp_path}"
    end

    test "uses unique tmp_path per agent" do
      name = "unique-#{System.unique_integer([:positive])}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, agent_id} =
        Agents.create_agent(AgentTestHelpers.current_space_id(), model,
          name: name,
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      AgentTestHelpers.ensure_cleanup(agent_id)

      {:ok, pid} = Nest.Agents.Supervisor.get_agent(AgentTestHelpers.current_space_id(), agent_id)

      # allowlist: snapshot — tmp_path
      state = :sys.get_state(pid, 1_000)

      assert state.tmp_path == agent_tmp_path(current_space_id(), name)
    end

    test "cleans up tmp directory when stopped via Supervisor.stop_agent/2" do
      name = "delete-#{System.unique_integer([:positive])}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, agent_id} =
        Agents.create_agent(AgentTestHelpers.current_space_id(), model,
          name: name,
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      AgentTestHelpers.ensure_cleanup(agent_id)

      expected_tmp_path = agent_tmp_path(current_space_id(), name)

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      {:ok, pid} = Nest.Agents.Supervisor.get_agent(AgentTestHelpers.current_space_id(), agent_id)
      ref = Process.monitor(pid)

      :ok = Nest.Agents.Supervisor.stop_agent(AgentTestHelpers.current_space_id(), agent_id)
      wait_for_down(ref, pid, :_)

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed after stop: #{expected_tmp_path}"
    end

    test "cleans up tmp directory when agent crashes" do
      Process.flag(:trap_exit, true)

      {pid, name} = start_agent()
      expected_tmp_path = agent_tmp_path(current_space_id(), name)

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      ref = Process.monitor(pid)

      capture_log(fn ->
        Process.exit(pid, :crash)
        wait_for_down(ref, pid, :crash)
      end)

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed after agent crash: #{expected_tmp_path}"
    end

    test "cleans up tmp directory when linked process dies" do
      Process.flag(:trap_exit, true)

      {pid, name} = start_agent()
      expected_tmp_path = agent_tmp_path(current_space_id(), name)

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      ref = Process.monitor(pid)

      Process.exit(pid, :shutdown)
      wait_for_down(ref, pid, :shutdown)

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed when linked process dies: #{expected_tmp_path}"
    end

    test "agent tmp dirs are removed per-agent on stop, leaving the space dir" do
      Process.flag(:trap_exit, true)

      unique = System.unique_integer([:positive])
      name1 = "parent-cleanup-a-#{unique}"
      name2 = "parent-cleanup-b-#{unique}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}
      vid = AgentTestHelpers.vocation_id_for_test()
      space_id = AgentTestHelpers.current_space_id()

      {:ok, agent_id1} =
        Agents.create_agent(space_id, model, name: name1, vocation_id: vid)

      AgentTestHelpers.ensure_cleanup(agent_id1)

      {:ok, agent_id2} =
        Agents.create_agent(space_id, model, name: name2, vocation_id: vid)

      AgentTestHelpers.ensure_cleanup(agent_id2)

      path1 = agent_tmp_path(space_id, name1)
      path2 = agent_tmp_path(space_id, name2)

      assert File.exists?(path1)
      assert File.exists?(path2)

      {:ok, pid1} = Nest.Agents.Supervisor.get_agent(space_id, agent_id1)
      {:ok, pid2} = Nest.Agents.Supervisor.get_agent(space_id, agent_id2)

      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      :ok = Nest.Agents.Supervisor.stop_agent(space_id, agent_id1)
      wait_for_down(ref1, pid1, :shutdown)

      refute File.exists?(path1)
      assert File.exists?(path2)

      :ok = Nest.Agents.Supervisor.stop_agent(space_id, agent_id2)
      wait_for_down(ref2, pid2, :shutdown)

      refute File.exists?(path2)

      # The space dir is a shared parent and is NEVER rmdir'd by an
      # agent's terminate/2 (a sibling's mkdir_p! racing a terminate
      # was a real bug). It is left to OS /tmp cleanup.
      assert File.dir?(space_dir(space_id))
    end
  end

  # Wait for the monitored process to go down. `assert_receive/2` is a
  # selective receive, so unrelated messages (e.g. a sibling async
  # test's `{:EXIT, _, _}` leaking into this test's `trap_exit`
  # mailbox) are left in the mailbox and ignored — no drain loop is
  # needed. The `:DOWN` is the event and the 1s fence is only the
  # failure bound. Pass `reason = :_` to accept any reason.
  defp wait_for_down(ref, pid, :_) do
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  defp wait_for_down(ref, pid, reason) do
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, 1_000
  end
end
