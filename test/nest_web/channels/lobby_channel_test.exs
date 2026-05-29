defmodule NestWeb.LobbyChannelTest do
  @moduledoc """
  Tests for the LobbyChannel.
  """
  use NestWeb.ChannelCase

  alias Nest.Agents
  alias Nest.Vocations

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for id <- Nest.Agents.list_agents() do
      Nest.Agents.delete_agent(id.id)
    end

    # Clean up any vocations from previous tests
    for v <- Vocations.list_vocations() do
      Vocations.delete_vocation(v)
    end

    :ok
  end

  describe "join/3" do
    test "returns agents, models, and vocations on join" do
      # Connect socket and join lobby
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      # After joining, we should receive initial state
      assert_push "init", payload
      assert is_list(payload.agents)
      assert is_list(payload.models)
      assert is_list(payload.vocations)
    end

    test "returns vocations with correct JSON structure" do
      # Create a test vocation BEFORE joining
      {:ok, _vocation} =
        Vocations.create_vocation(%{
          name: "Test Vocation",
          description: "A test vocation",
          system_prompt: "You are a test assistant.",
          tools: ["read_file"],
          modes: %{"chat" => %{}}
        })

      # Now connect socket and join lobby
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      assert_push "init", payload

      # Verify vocations is a list
      assert is_list(payload.vocations)

      # Find our test vocation
      test_vocation = Enum.find(payload.vocations, fn v -> v.name == "Test Vocation" end)
      assert test_vocation != nil
      assert test_vocation.description == "A test vocation"
      assert test_vocation.system_prompt == "You are a test assistant."
      assert test_vocation.tools == ["read_file"]
      assert test_vocation.modes == %{"chat" => %{}}
    end

    test "vocations are JSON-serializable and roundtrip correctly" do
      # Create a test vocation with all fields BEFORE joining
      {:ok, _vocation} =
        Vocations.create_vocation(%{
          name: "JSON Test Vocation",
          description: "Testing JSON encoding",
          system_prompt: "System prompt here",
          tools: ["read_file", "write_file"],
          modes: %{"chat" => %{"net" => false}, "build" => %{"net" => true}}
        })

      # Now connect socket and join lobby
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      assert_push "init", payload

      # Verify the payload can be encoded to JSON
      assert {:ok, json} = Jason.encode(payload)

      # Verify we can decode it back
      assert {:ok, decoded} = Jason.decode(json)

      # Verify vocations are present and have correct structure
      assert is_list(decoded["vocations"])
      assert decoded["vocations"] != []

      # Find and verify our test vocation in the decoded payload
      test_vocation =
        Enum.find(decoded["vocations"], fn v -> v["name"] == "JSON Test Vocation" end)

      assert test_vocation != nil
      assert test_vocation["description"] == "Testing JSON encoding"
      assert test_vocation["system_prompt"] == "System prompt here"
      assert test_vocation["tools"] == ["read_file", "write_file"]
      assert test_vocation["modes"] == %{"chat" => %{"net" => false}, "build" => %{"net" => true}}
    end

    test "returns models with correct JSON structure" do
      # Connect socket and join lobby
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

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
      # Connect socket and join lobby
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

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
    test "creates agent and broadcasts event" do
      # Connect socket and join lobby
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      ref = push(socket, "create_agent", %{"model" => %{"name" => "qwen3.5-plus"}})
      assert_reply ref, :ok, %{"id" => id}
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, id)
      assert_broadcast "agent:created", %{"id" => ^id, "model" => %{"name" => "qwen3.5-plus"}}
    end
  end

  describe "handle_in(delete_agent)" do
    test "deletes agent and broadcasts event" do
      # Connect socket and join lobby
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      # First create an agent
      {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})

      ref = push(socket, "delete_agent", %{"id" => id})
      assert_reply ref, :ok, %{}
      assert_broadcast "agent:deleted", %{"id" => ^id}

      # Verify agent is gone
      assert {:error, :not_found} = Agents.get_agent(id)
    end

    test "returns error for non-existent agent" do
      # Connect socket and join lobby
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      ref = push(socket, "delete_agent", %{"id" => "nonexistent"})
      assert_reply ref, :error, %{"reason" => "not_found"}
    end
  end
end
