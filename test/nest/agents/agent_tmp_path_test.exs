defmodule Nest.Agents.AgentTmpPathTest do
  @moduledoc """
  Agent tmp_path lifecycle tests. `async: true`. The
  `/tmp/nest-VMPID/agent-NAME/` dirs are per-VM shared
  state, but each test uses a fresh `System.unique_integer/1`
  agent name and asserts on its own dir; concurrent tests'
  dirs sit at their own VMPID+name path and don't collide.

  IMPORTANT: the shared parent `/tmp/nest-VMPID/` must NEVER
  be wiped (in setup or on_exit). It is process-global across
  all agents/tests in this BEAM. A `File.rm_rf` on it races
  with a concurrent async test's agent that is mid-`shell_cmd`:
  the wipe deletes that agent's tmp dir while bwrap is starting,
  producing `bwrap: Can't find source path` (exit_code=1).
  Per-agent dirs are unique (via `System.unique_integer/1`) and
  cleaned by their own `terminate/2`, so a parent wipe buys
  nothing and only causes this flake. The parent is left in
  place and cleared by system `/tmp` cleanup (see
  `Nest.Agents.Agent.TmpSpace`).
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
    # error (exit_code=1). Each test below uses a unique agent name
    # and cleans up its own dir, so the parent must be left alone.

    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "tmp_path lifecycle" do
    test "creates tmp directory on agent start" do
      {_pid, agent_id} = start_agent()
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      assert File.dir?(expected_tmp_path)
    end

    test "passes tmp_path to agent state" do
      {pid, _agent_id} = start_agent()
      info = Agent.get_public_info(pid)

      assert info.tmp_path =~ ~r|/tmp/nest-#{System.pid()}/agent-|,
             "Expected tmp_path to match pattern, got: #{inspect(info.tmp_path)}"
    end

    test "cleans up tmp directory on agent termination" do
      {pid, agent_id} = start_agent()
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

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
      info = Agent.get_public_info(pid)

      assert info.tmp_path =~ ~r|/tmp/nest-#{System.pid()}/agent-#{name}|
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

      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

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

      {pid, agent_id} = start_agent()
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

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

      {pid, agent_id} = start_agent()
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      ref = Process.monitor(pid)

      Process.exit(pid, :shutdown)
      wait_for_down(ref, pid, :shutdown)

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed when linked process dies: #{expected_tmp_path}"
    end

    test "agent tmp dirs are removed per-agent on stop" do
      Process.flag(:trap_exit, true)

      unique = System.unique_integer([:positive])
      name1 = "parent-cleanup-a-#{unique}"
      name2 = "parent-cleanup-b-#{unique}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}
      vid = AgentTestHelpers.vocation_id_for_test()

      {:ok, agent_id1} =
        Agents.create_agent(AgentTestHelpers.current_space_id(), model,
          name: name1,
          vocation_id: vid
        )

      AgentTestHelpers.ensure_cleanup(agent_id1)

      {:ok, agent_id2} =
        Agents.create_agent(AgentTestHelpers.current_space_id(), model,
          name: name2,
          vocation_id: vid
        )

      AgentTestHelpers.ensure_cleanup(agent_id2)

      parent_dir = "/tmp/nest-#{System.pid()}"
      path1 = "#{parent_dir}/agent-#{agent_id1}"
      path2 = "#{parent_dir}/agent-#{agent_id2}"

      assert File.exists?(path1)
      assert File.exists?(path2)

      {:ok, pid1} =
        Nest.Agents.Supervisor.get_agent(AgentTestHelpers.current_space_id(), agent_id1)

      {:ok, pid2} =
        Nest.Agents.Supervisor.get_agent(AgentTestHelpers.current_space_id(), agent_id2)

      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      :ok = Nest.Agents.Supervisor.stop_agent(AgentTestHelpers.current_space_id(), agent_id1)
      wait_for_down(ref1, pid1, :shutdown)

      refute File.exists?(path1)
      assert File.exists?(path2)

      :ok = Nest.Agents.Supervisor.stop_agent(AgentTestHelpers.current_space_id(), agent_id2)
      wait_for_down(ref2, pid2, :shutdown)

      refute File.exists?(path2)
    end
  end

  # Wait for the monitored process to go down, discarding any
  # unrelated messages (e.g. a sibling async test's `{:EXIT, _, _}`
  # leaking into this test's `trap_exit` mailbox). A short fixed
  # timeout is flaky under concurrent load, so poll with a
  # generous deadline instead. Pass `reason = :_` to accept any.
  defp wait_for_down(ref, pid, reason) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_for_down(ref, pid, reason, deadline)
  end

  defp do_wait_for_down(ref, pid, reason, deadline) do
    receive do
      {:DOWN, ^ref, :process, ^pid, ^reason} -> :ok
      {:DOWN, ^ref, :process, ^pid, _} when reason == :_ -> :ok
      _ -> maybe_wait_more(ref, pid, reason, deadline)
    after
      50 ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("agent #{inspect(pid)} did not go down within 2s")
        else
          maybe_wait_more(ref, pid, reason, deadline)
        end
    end
  end

  defp maybe_wait_more(ref, pid, reason, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("agent #{inspect(pid)} did not go down within 2s")
    else
      do_wait_for_down(ref, pid, reason, deadline)
    end
  end
end
