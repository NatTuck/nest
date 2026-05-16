defmodule Nest.AgentsTest do
  @moduledoc """
  Tests for the Agents context module.
  """
  use ExUnit.Case

  import Eventually

  alias Nest.Agents

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for agent <- Agents.list_agents() do
      Agents.delete_agent(agent.id)
    end

    :ok
  end

  describe "create_agent/1" do
    test "creates agent with model map" do
      # Use a model map directly instead of looking up from DotConfig
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus", provider: "model-studio"})
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
      assert {:ok, agent} = Agents.get_agent(id)
      assert agent.model.name == "qwen3.5-plus"
    end

    test "returns error for invalid model" do
      # Models must exist in config to create an agent
      assert {:error, %Nest.ChatModel.ModelNotFoundError{}} =
               Agents.create_agent(%{name: "custom-model"})
    end
  end

  describe "get_agent/1" do
    test "returns agent state" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, agent} = Agents.get_agent(id)
      assert agent.id == id
      assert agent.model.name == "qwen3.5-plus"
      assert agent.status == :idle
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.get_agent("nonexistent")
    end
  end

  describe "list_agents/0" do
    test "returns list of agents" do
      {:ok, id1} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, id2} = Agents.create_agent(%{name: "MiniMax-M2.5"})

      agents = Agents.list_agents()
      assert length(agents) == 2
      assert Enum.any?(agents, &(&1.id == id1))
      assert Enum.any?(agents, &(&1.id == id2))
    end

    test "returns empty list when no agents" do
      assert Agents.list_agents() == []
    end
  end

  describe "chat/2" do
    test "sends message to agent" do
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      :ok = Agents.chat(id, "Hello, agent!")

      {:ok, agent} = Agents.get_agent(id)
      assert length(agent.messages) == 1
      assert hd(agent.messages).role == :user
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
               Agents.get_agent(id) == {:error, :not_found}
             end)
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agents.delete_agent("nonexistent")
    end
  end
end
