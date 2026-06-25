defmodule Nest.Agents.AgentTmpPathTest do
  @moduledoc """
  Agent tmp_path lifecycle tests. These are in a separate `async: false`
  module because the agent's tmp_path is /tmp/nest-VMPID/ which is
  shared across all tests in the BEAM VM. Concurrent async tests'
  cleanup can wipe the parent dir and cause these tests to flake.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    # Wipe the parent tmp dir at setup; safe because the module is
    # async: false. Other tests' agents are also wiped — this is
    # acceptable because the parent dir is per-VM shared state.
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
      {_pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      assert File.dir?(expected_tmp_path)
    end

    test "passes tmp_path to agent state" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      info = Agent.get_public_info(pid)

      assert info.tmp_path =~ ~r|/tmp/nest-#{System.pid()}/agent-|,
             "Expected tmp_path to match pattern, got: #{inspect(info.tmp_path)}"
    end

    test "cleans up tmp directory on agent termination" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path)

      ref = Process.monitor(pid)
      Agent.terminate(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed: #{expected_tmp_path}"
    end

    test "uses unique tmp_path per agent" do
      agent_id1 = "unique-test-1-#{System.unique_integer([:positive])}"
      pid1 = start_supervised!({Agent, %{id: agent_id1, model: %{name: "qwen3.5-plus"}}})
      info1 = Agent.get_public_info(pid1)

      assert info1.tmp_path =~ ~r|/tmp/nest-#{System.pid()}/agent-#{agent_id1}|
    end

    test "cleans up tmp directory when stopped via Supervisor.stop_agent/1" do
      alias Nest.Agents.Supervisor

      {:ok, agent_id} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      expected_tmp_path = "/tmp/nest-#{System.pid()}/agent-#{agent_id}"

      assert File.exists?(expected_tmp_path),
             "Expected tmp directory to exist: #{expected_tmp_path}"

      {:ok, pid} = Supervisor.get_agent(agent_id)
      ref = Process.monitor(pid)

      :ok = Supervisor.stop_agent(agent_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      refute File.exists?(expected_tmp_path),
             "Expected tmp directory to be removed after Supervisor.stop_agent: #{expected_tmp_path}"
    end

    test "cleans up tmp directory when agent crashes" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
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
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
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
      alias Nest.Agents.Supervisor

      unique = System.unique_integer([:positive])
      id1 = "parent-cleanup-a-#{unique}"
      id2 = "parent-cleanup-b-#{unique}"

      {:ok, agent_id1} = Supervisor.start_agent(%{id: id1, model: %{name: "qwen3.5-plus"}})
      {:ok, agent_id2} = Supervisor.start_agent(%{id: id2, model: %{name: "qwen3.5-plus"}})

      parent_dir = "/tmp/nest-#{System.pid()}"
      path1 = "#{parent_dir}/agent-#{agent_id1}"
      path2 = "#{parent_dir}/agent-#{agent_id2}"

      assert File.exists?(path1)
      assert File.exists?(path2)

      {:ok, pid1} = Supervisor.get_agent(agent_id1)
      {:ok, pid2} = Supervisor.get_agent(agent_id2)
      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      :ok = Supervisor.stop_agent(agent_id1)
      assert_receive {:DOWN, ^ref1, :process, ^pid1, _reason}, 100

      refute File.exists?(path1)
      assert File.exists?(path2)

      :ok = Supervisor.stop_agent(agent_id2)
      assert_receive {:DOWN, ^ref2, :process, ^pid2, _reason}, 100

      refute File.exists?(path2)
    end
  end
end
