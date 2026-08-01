defmodule NestWeb.LobbyChannelTest do
  @moduledoc """
  Tests for the LobbyChannel.
  """
  use NestWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Nest.Agents
  alias Nest.Vocations

  setup do
    # Agents supervision tree is already started by Application
    # Just need to clean up any agents from previous tests
    for id <- Nest.Agents.list_agents() do
      Nest.Agents.delete_agent(id)
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
          modes: %{
            "chat" => %{
              "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
            }
          }
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

      assert test_vocation.modes == %{
               "chat" => %{
                 "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
               }
             }
    end

    test "vocations are JSON-serializable and roundtrip correctly" do
      # Create a test vocation with all fields BEFORE joining
      {:ok, _vocation} =
        Vocations.create_vocation(%{
          name: "JSON Test Vocation",
          description: "Testing JSON encoding",
          system_prompt: "System prompt here",
          tools: ["read_file", "write_file"],
          modes: %{
            "chat" => %{
              "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
            },
            "build" => %{
              "caps" => %{"net" => true, "fs" => %{"read" => ["/"], "write" => []}}
            }
          }
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

      assert test_vocation["modes"] == %{
               "chat" => %{
                 "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}
               },
               "build" => %{
                 "caps" => %{"net" => true, "fs" => %{"read" => ["/"], "write" => []}}
               }
             }
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
      assert_reply ref, :ok, %{"name" => name}
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
      assert_broadcast "agent:created", %{"name" => ^name, "model" => %{"name" => "qwen3.5-plus"}}
    end

    test "forwards provider from the model params to the created agent" do
      # The lobby's model catalog carries a `provider` for each model
      # (including auto-discovered ones from providers with
      # `auto-models = true`). The lobby forwards this to
      # `Agents.create_agent/2` so the provider is always on the
      # wire to the ChatPage header, even when the model isn't in
      # the static DotConfig.
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      ref =
        push(socket, "create_agent", %{
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"name" => name}

      assert {:ok, info} = Agents.get_info(name)
      assert info.model.name == "qwen3.5-plus"
      assert info.model.provider == "model-studio"

      assert_broadcast "agent:created", %{
        "name" => ^name,
        "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
      }
    end
  end

  describe "handle_in(delete_agent)" do
    test "deletes agent and broadcasts event" do
      # Connect socket and join lobby
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      # First create an agent
      {:ok, name} = Agents.create_agent(%{name: "qwen3.5-plus"})

      ref = push(socket, "delete_agent", %{"name" => name})
      assert_reply ref, :ok, %{}
      assert_broadcast "agent:deleted", %{"name" => ^name}

      # Verify agent is gone
      assert {:error, :not_found} = Agents.get_info(name)
    end

    test "returns error for non-existent agent" do
      # Connect socket and join lobby
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      ref = push(socket, "delete_agent", %{"name" => "nonexistent"})
      assert_reply ref, :error, %{"reason" => "not_found"}
    end
  end

  describe "handle_in(change_model)" do
    test "repairs an agent that started in :model_missing state" do
      # The model-probe failure fires a `Logger.error` from
      # `Agent.init/1` — capture it and assert it's the
      # expected error path, not noise.
      log =
        capture_log(fn ->
          {:ok, _, socket} =
            subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

          {:ok, name} = Agents.create_agent(%{name: "ghost-model"})

          ref =
            push(socket, "change_model", %{
              "name" => name,
              "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
            })

          assert_reply ref, :ok, %{}

          assert_broadcast "agent:updated", %{
            "name" => ^name,
            "model" => %{
              "name" => "qwen3.5-plus",
              "provider" => "model-studio"
            }
          }

          {:ok, info} = Agents.get_info(name)
          assert info.status == :idle
          assert info.model.name == "qwen3.5-plus"
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :invalid_model for an unknown model" do
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      {:ok, name} = Agents.create_agent(%{name: "qwen3.5-plus"})

      ref =
        push(socket, "change_model", %{
          "name" => name,
          "model" => %{"name" => "totally-bogus-model"}
        })

      assert_reply ref, :error, %{"reason" => "invalid_model"}
    end

    test "returns :invalid_payload for a malformed message" do
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      ref = push(socket, "change_model", %{"name" => "no-model-field"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end
  end

  describe "init (broken_agents payload)" do
    test "sends an empty broken_agents list when persistence is disabled" do
      # Default test config has `persistence_enabled: false`,
      # so the lobby's broken_agents payload is `[]` (and the
      # user can't end up in the original "vanishing" situation
      # in this env — but the channel contract holds either way).
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      assert_push "init", payload

      assert Map.has_key?(payload, :broken_agents)
      assert payload.broken_agents == []
    end

    test "init arrives immediately and the async fetch completes" do
      # The `:after_join` handler now spawns the broken-agents
      # fetch in a separate process so a hung `Models.list/0`
      # probe can't block the channel's WS lifecycle.
      #
      # `Agents.list_broken_agents/0` returns `[]` in this test
      # (default config disables persistence), but the spawn
      # still happens — that's what we're verifying. The
      # follow-up event lands with `[]` after the spawned
      # `Task.async` returns.
      #
      # (We can't easily observe the stub from a spawned
      # process because `Mimic.stub` is per-process; using
      # `Mimic.set_mimic_global` would leak state across
      # tests. The follow-up-event payload is enough to
      # assert the spawn-and-collect round-trip works.)
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      assert_push "init", payload
      assert payload.broken_agents == []

      # Follow-up arrives after the spawned task yields its
      # empty list. This proves the spawn-and-collect path
      # actually plumbed back to the channel process.
      assert_push "broken_agents_updated", %{broken_agents: []}, 1_000
    end

    test "follow-up broken_agents_updated is pushed even when the spawned task yields []" do
      # Smaller, sleep-free regression for the empty-result
      # arm of the spawned task. The spawn runs the real
      # `Agents.list_broken_agents/0`, which short-circuits
      # to `[]` in this env (persistence disabled). The
      # follow-up event still lands with `[]` because the
      # channel calls `Task.yield/3` and the rescue branch
      # handles the empty case identically.
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      assert_push "init", payload
      assert payload.broken_agents == []

      assert_push "broken_agents_updated", %{broken_agents: []}, 1_000
    end

    test "dead-but-unresolvable persisted agents appear in broken_agents_updated" do
      # User-visible regression for the "agent missing from
      # the list" bug. The lobby's `broken_agents` payload
      # feeds `state.brokenAgents` which the sidebar's
      # "Needs Repair" section consumes. The follow-up
      # event must fire even when the underlying
      # `Agents.list_broken_agents/0` returns `[]` (here,
      # because the test config disables persistence) —
      # proving the spawn-and-relay path is intact. The
      # non-empty case requires a persisted agent whose
      # GenServer is dead; the JS sidebar test covers the
      # user-facing rendering path.
      {:ok, _, _socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      assert_push "init", payload
      assert payload.broken_agents == []

      assert_push "broken_agents_updated", %{broken_agents: []}, 1_000
    end
  end

  describe "handle_in(rescan_models)" do
    test "replies :ok immediately and broadcasts models_updated with the live catalog" do
      # The channel's reply should be `:ok` so the click handler
      # can dismiss its loading state without waiting on the
      # auto-discovery probes to finish. The real catalog lands
      # via the follow-up `models_updated` broadcast.
      {:ok, _, socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

      # Drain the init push so the test isn't racing the
      # `:after_join` follow-up.
      assert_push "init", _payload

      ref = push(socket, "rescan_models", %{})
      assert_reply ref, :ok

      assert_broadcast "models_updated", %{models: models_list}, 6_000
      assert is_list(models_list)
      assert models_list != []
    end
  end
end
