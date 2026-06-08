defmodule Nest.Agents.SupervisorTest do
  @moduledoc """
  Tests for the Agent Supervisor.
  """
  use ExUnit.Case

  alias Nest.Agents.{Registry, Supervisor}
  alias Nest.Test.TaskDrain

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for id <- Supervisor.list_agents() do
      Supervisor.stop_agent(id)
    end

    parent_dir = "/tmp/nest-#{System.pid()}"
    File.rm_rf(parent_dir)
    on_exit(fn -> File.rm_rf(parent_dir) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  describe "start_agent/1" do
    test "starts agent with generated ID" do
      {:ok, id} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
      assert {:ok, _pid} = Registry.lookup(id)
    end

    test "starts agent with explicit ID" do
      {:ok, "custom-id"} =
        Supervisor.start_agent(%{id: "custom-id", model: %{name: "qwen3.5-plus"}})

      assert {:ok, _pid} = Registry.lookup("custom-id")
    end

    test "returns error for duplicate ID" do
      {:ok, "duplicate"} =
        Supervisor.start_agent(%{id: "duplicate", model: %{name: "qwen3.5-plus"}})

      assert {:error, :already_exists} =
               Supervisor.start_agent(%{id: "duplicate", model: %{name: "qwen3.5-plus"}})
    end
  end

  describe "stop_agent/1" do
    test "stops agent and removes from registry" do
      {:ok, id} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      assert {:ok, pid} = Registry.lookup(id)
      assert Process.alive?(pid)

      :ok = Supervisor.stop_agent(id)

      # Wait for process to stop
      Process.sleep(50)
      assert {:error, :not_found} = Registry.lookup(id)
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Supervisor.stop_agent("nonexistent")
    end
  end

  describe "list_agents/0" do
    test "returns list of running agent IDs" do
      {:ok, id1} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      {:ok, id2} = Supervisor.start_agent(%{model: %{name: "MiniMax-M2.5"}})

      agents = Supervisor.list_agents()
      assert length(agents) == 2
      assert id1 in agents
      assert id2 in agents
    end

    test "returns empty list when no agents" do
      assert Supervisor.list_agents() == []
    end
  end

  describe "get_agent/1" do
    test "returns agent PID by ID" do
      {:ok, id} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      {:ok, pid} = Supervisor.get_agent(id)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Supervisor.get_agent("nonexistent")
    end
  end
end
