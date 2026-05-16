defmodule NestWeb.LobbyChannelTest do
  @moduledoc """
  Tests for the LobbyChannel.
  """
  use NestWeb.ChannelCase

  alias Nest.Agents

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for id <- Nest.Agents.list_agents() do
      Nest.Agents.delete_agent(id.id)
    end

    # Connect socket and join lobby
    {:ok, _, socket} =
      subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

    {:ok, socket: socket}
  end

  describe "join/3" do
    test "returns agents and models on join" do
      # After joining, we should receive initial state
      assert_push "init", payload
      assert is_list(payload.agents)
      assert is_list(payload.models)
    end

    test "returns models with correct JSON structure" do
      assert_push "init", payload

      # Verify models is a non-empty list from test/data/config.toml
      assert is_list(payload.models)
      assert payload.models != []

      # Verify each model has string keys (not atoms) for JSON serialization
      Enum.each(payload.models, fn model ->
        assert is_map(model)
        assert Map.has_key?(model, "name")
        assert Map.has_key?(model, "provider")
        assert Map.has_key?(model, "context_limit")

        assert is_binary(model["name"])
        assert is_binary(model["provider"])
        assert is_integer(model["context_limit"]) or is_nil(model["context_limit"])
      end)

      # Verify specific models from test/data/config.toml
      qwen_model = Enum.find(payload.models, fn m -> m["name"] == "qwen3.5-plus" end)
      assert qwen_model != nil
      assert qwen_model["provider"] == "model-studio"
      assert qwen_model["context_limit"] == 512_000

      minimax_model = Enum.find(payload.models, fn m -> m["name"] == "MiniMax-M2.5" end)
      assert minimax_model != nil
      assert minimax_model["provider"] == "model-studio"
      assert minimax_model["context_limit"] == nil
    end

    test "model structure is JSON-serializable" do
      assert_push "init", payload

      # Verify the payload can be encoded to JSON
      # This ensures no atoms that would break JSON serialization
      assert {:ok, json} = Jason.encode(payload)

      # Verify we can decode it back and get the same structure
      assert {:ok, decoded} = Jason.decode(json)
      assert is_list(decoded["models"])
      assert decoded["models"] != []

      # Verify decoded models have string keys
      first_model = List.first(decoded["models"])
      assert is_binary(first_model["name"])
      assert is_binary(first_model["provider"])
    end
  end

  describe "handle_in(create_agent)" do
    test "creates agent and broadcasts event", %{socket: socket} do
      ref = push(socket, "create_agent", %{"model" => %{"name" => "qwen3.5-plus"}})
      assert_reply ref, :ok, %{"id" => id}
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
      assert_broadcast "agent:created", %{"id" => ^id, "model" => %{"name" => "qwen3.5-plus"}}
    end
  end

  describe "handle_in(delete_agent)" do
    test "deletes agent and broadcasts event", %{socket: socket} do
      # First create an agent
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})

      ref = push(socket, "delete_agent", %{"id" => id})
      assert_reply ref, :ok, %{}
      assert_broadcast "agent:deleted", %{"id" => ^id}

      # Verify agent is gone
      assert {:error, :not_found} = Agents.get_agent(id)
    end

    test "returns error for non-existent agent", %{socket: socket} do
      ref = push(socket, "delete_agent", %{"id" => "nonexistent"})
      assert_reply ref, :error, %{"reason" => "not_found"}
    end
  end
end
