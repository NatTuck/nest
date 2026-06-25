defmodule Nest.Agents.SupervisorTest do
  @moduledoc """
  Tests for the Agent Supervisor.
  """
  use ExUnit.Case, async: true

  import Eventually

  alias Nest.Agents.{Registry, Supervisor}

  setup do
    # Note: we deliberately do NOT call `Supervisor.stop_agent/1`
    # on every existing agent here. With `async: true`, that would
    # kill agents created by other concurrent tests (e.g. the
    # channel tests' per-test agents), which then fail with
    # "agent not found" at subscribe_and_join. Per-test cleanup
    # belongs in the test that owns the agent, not in a shared
    # setup block.
    #
    # We also don't wipe /tmp/nest-VMPID/ because the path is
    # shared across all tests in this BEAM VM and wiping in setup
    # races with concurrent async tests' agents. Per-agent cleanup
    # is the agent's own responsibility in `terminate/2`.

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

      # The registry's auto-cleanup happens asynchronously after the
      # process exits, so poll until the lookup reflects the removal.
      assert eventually(fn -> Registry.lookup(id) == {:error, :not_found} end,
               timeout: 1000
             )
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Supervisor.stop_agent("nonexistent")
    end
  end

  describe "list_agents/0" do
    test "returns list of running agent IDs" do
      {:ok, id1} = Supervisor.start_agent(%{model: %{name: "qwen3.5-plus"}})
      {:ok, id2} = Supervisor.start_agent(%{model: %{name: "MiniMax-M2.5"}})

      # In async mode, other tests may have started/stopped agents
      # concurrently. Assert on this test's own IDs (definitely
      # present) and an inclusive lower bound on the total — not
      # an exact count.
      agents = Supervisor.list_agents()
      assert id1 in agents
      assert id2 in agents
      assert length(agents) >= 2
    end

    # The "returns empty list when no agents" test is not expressible
    # in async mode (other tests' agents leak in). It would belong
    # in a separate `async: false` describe block or a dedicated
    # module. Tracked as future work.
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
