defmodule Nest.AgentsTest do
  @moduledoc """
  Tests for the Agents context module.
  """
  use ExUnit.Case, async: false

  import Eventually
  import Mimic

  alias Nest.Agents

  setup :verify_on_exit!

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for id <- Agents.list_agents() do
      Agents.delete_agent(id)
    end

    # Note: we don't wipe /tmp/nest-VMPID/ because the path is
    # shared across all tests in this BEAM VM and wiping in setup
    # races with concurrent async tests' agents. Per-agent cleanup
    # is the agent's own responsibility in `terminate/2`.

    :ok
  end

  describe "create_agent/1" do
    test "creates agent with model map" do
      # Use a model map directly instead of looking up from DotConfig
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus", provider: "model-studio"})
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
      assert {:ok, info} = Agents.get_info(id)
      assert info.model.name == "qwen3.5-plus"
    end

    test "enriches model with provider from DotConfig when only :name is given" do
      # Callers (e.g. NewAgentPage) send just %{name: ...}; the API
      # looks up the provider so the chat header can render
      # "provider: model-name".
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      assert {:ok, info} = Agents.get_info(id)
      assert info.model.name == "qwen3.5-plus"
      assert info.model.provider == "model-studio"
    end

    test "returns error for invalid model" do
      # Models must exist in config to create an agent
      assert {:error, %Nest.ChatModel.ModelNotFoundError{}} =
               Agents.create_agent(%{name: "custom-model"})
    end
  end

  describe "get_info/1" do
    test "returns agent public info" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, info} = Agents.get_info(id)
      assert info.id == id
      assert info.model.name == "qwen3.5-plus"
      assert info.status == :idle
      assert info.message_count == 1
      assert info.partial == nil
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.get_info("nonexistent")
    end
  end

  describe "list_agents/0" do
    test "returns list of agent IDs" do
      {:ok, id1} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, id2} = Agents.create_agent(%{name: "MiniMax-M2.5"})

      # This file is async; other tests' agents may be in the
      # registry too. Verify our two are present rather than
      # asserting a count.
      agents = Agents.list_agents()
      assert id1 in agents
      assert id2 in agents
    end

    test "returns empty list when no agents" do
      assert Agents.list_agents() == []
    end
  end

  describe "list_agents_info/0" do
    test "returns list of agent info" do
      {:ok, id1} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, id2} = Agents.create_agent(%{name: "MiniMax-M2.5"})

      # See note in list_agents/0 test: async file, so we only
      # verify our two IDs are present, not the total count.
      agents_info = Agents.list_agents_info()
      assert Enum.any?(agents_info, fn info -> info.id == id1 end)
      assert Enum.any?(agents_info, fn info -> info.id == id2 end)
    end

    test "returns empty list when no agents" do
      assert Agents.list_agents_info() == []
    end
  end

  describe "chat/2" do
    test "sends message to agent" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      :ok = Agents.chat(id, "Hello, agent!")

      # Verify via get_info that message count increased
      {:ok, info} = Agents.get_info(id)
      assert info.message_count == 2
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.chat("nonexistent", "Hello")
    end
  end

  describe "delete_agent/1" do
    test "removes agent" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      :ok = Agents.delete_agent(id)

      assert eventually(fn ->
               Agents.get_info(id) == {:error, :not_found}
             end)
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.delete_agent("nonexistent")
    end
  end
end
