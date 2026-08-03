defmodule Nest.Agents.AgentTmpPathTest do
  @moduledoc """
  Agent tmp_path lifecycle tests. `async: true`. The
  `/tmp/nest-VMPID/agent-NAME/` dirs are per-VM shared
  state, but each test uses a fresh `System.unique_integer/1`
  agent name and asserts on its own dir; concurrent tests'
  dirs sit at their own VMPID+name path and don't collide.
  The per-test setup still wipes this VM's parent dir so a
  flaky earlier test doesn't leave stale dirs behind.
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
    parent_dir = "/tmp/nest-#{System.pid()}"
    File.rm_rf(parent_dir)
    on_exit(fn -> File.rm_rf(parent_dir) end)

    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

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
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed: #{expected_tmp_path}"
    end

    test "uses unique tmp_path per agent" do
      name = "unique-#{System.unique_integer([:positive])}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, agent_id} =
        Agents.create_agent(model,
          name: name,
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      {:ok, pid} = Nest.Agents.Supervisor.get_agent(agent_id)
      info = Agent.get_public_info(pid)

      assert info.tmp_path =~ ~r|/tmp/nest-#{System.pid()}/agent-#{name}|
    end

    test "cleans up tmp directory when stopped via Agents.delete_agent/1" do
      name = "delete-#{System.unique_integer([:positive])}"
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, agent_id} =
        Agents.create_agent(model,
          name: name,
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      {:ok, pid} = Nest.Agents.Supervisor.get_agent(agent_id)
      ref = Process.monitor(pid)

      :ok = Agents.delete_agent(agent_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed after Agents.delete_agent: #{expected_tmp_path}"
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
        assert_receive {:DOWN, ^ref, :process, ^pid, :crash}, 100
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
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 100

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

      {:ok, agent_id1} = Agents.create_agent(model, name: name1, vocation_id: vid)
      {:ok, agent_id2} = Agents.create_agent(model, name: name2, vocation_id: vid)

      parent_dir = "/tmp/nest-#{System.pid()}"
      path1 = "#{parent_dir}/agent-#{agent_id1}"
      path2 = "#{parent_dir}/agent-#{agent_id2}"

      assert File.exists?(path1)
      assert File.exists?(path2)

      {:ok, pid1} = Nest.Agents.Supervisor.get_agent(agent_id1)
      {:ok, pid2} = Nest.Agents.Supervisor.get_agent(agent_id2)
      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      :ok = Agents.delete_agent(agent_id1)
      assert_receive {:DOWN, ^ref1, :process, ^pid1, _reason}, 100

      refute File.exists?(path1)
      assert File.exists?(path2)

      :ok = Agents.delete_agent(agent_id2)
      assert_receive {:DOWN, ^ref2, :process, ^pid2, _reason}, 100

      refute File.exists?(path2)
    end
  end
end
