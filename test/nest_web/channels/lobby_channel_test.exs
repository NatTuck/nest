defmodule NestWeb.LobbyChannelTest do
  @moduledoc """
  Tests for the LobbyChannel.
  """
  use NestWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Repo
  alias Nest.Vocations

  # The channel's `:after_join` spawns a supervised `Task` for
  # `broken_agents`; in async mode the inner `Repo.all` raises
  # `DBConnection.OwnershipError`, rescued to `[]` (module-level
  # `capture_log` swallows the death).
  #
  # Setup stops leftover agent pids (`Supervisor.stop_agent/1`
  # is idempotent) before deleting their DB rows; that's what
  # closes the parallel-test ghost-pid race window.
  setup do
    for name <- Nest.Persistence.list_agent_names() do
      _ = Supervisor.stop_agent(name)
      Nest.Persistence.delete_agent_by_name(name)
    end

    for v <- Vocations.list_vocations() do
      Vocations.delete_vocation(v)
    end

    # The channel handler's `default_vocation_id/0` falls back
    # to the first available vocation, so the test catalog
    # must always have at least one entry.
    _ = AgentTestHelpers.vocation_id_for_test()
    :ok
  end

  describe "join/3" do
    test "returns agents, models, and vocations on join" do
      # Connect socket and join lobby
      {_socket, payload} = join_lobby()

      # After joining, we should receive initial state
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
      {_socket, payload} = join_lobby()

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
      {_socket, payload} = join_lobby()

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
      {_socket, payload} = join_lobby()

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
      {_socket, payload} = join_lobby()

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
      {socket, _payload} = join_lobby()

      ref =
        push(socket, "create_agent", %{
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"name" => name}
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)

      # Register cleanup for the push-created agent so the
      # singleton `Nest.Agents.Supervisor` doesn't carry a
      # ghost pid into subsequent parallel tests — and so
      # the agent's mailbox can't fire DB calls after this
      # test has exited its sandbox checkout.
      AgentTestHelpers.ensure_cleanup(name)

      assert_broadcast "agent:created", %{
        "name" => ^name,
        "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
      }
    end

    test "forwards provider from the model params to the created agent" do
      # The lobby forwards the catalog's `provider` (whether from
      # static DotConfig or auto-discovery) so the wire shape is
      # always complete, even when the model isn't statically
      # configured.
      {socket, _payload} = join_lobby()

      ref =
        push(socket, "create_agent", %{
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"name" => name}
      AgentTestHelpers.ensure_cleanup(name)

      assert {:ok, info} = Agents.get_info(name)
      assert model_name(info.model) == "qwen3.5-plus"
      assert model_provider(info.model) == "model-studio"

      assert_broadcast "agent:created", %{
        "name" => ^name,
        "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
      }
    end
  end

  describe "handle_in(delete_agent)" do
    test "deletes agent and broadcasts event" do
      {socket, _payload} = join_lobby()

      # Create via the channel so the channel's
      # `default_vocation_id/0` fallback applies.
      # `Agents.create_agent/2` direct would skip that and
      # trip the NOT NULL constraint on `agents.vocation_id`.
      ref =
        push(socket, "create_agent", %{
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"name" => name}

      ref = push(socket, "delete_agent", %{"name" => name})
      assert_reply ref, :ok, %{}
      assert_broadcast "agent:deleted", %{"name" => ^name}

      # Verify agent is gone
      assert {:error, :not_found} = Agents.get_info(name)
    end

    test "returns error for non-existent agent" do
      # Connect socket and join lobby
      {socket, _payload} = join_lobby()

      ref = push(socket, "delete_agent", %{"name" => "nonexistent"})
      assert_reply ref, :error, %{"reason" => "not_found"}
    end
  end

  describe "handle_in(change_model)" do
    test "repairs an agent that started in :model_missing state" do
      # Capture the model-probe Logger.error — Agent.init/1
      # fires it when the model can't resolve. The `nil`
      # provider on the create_test_agent call forces the
      # model-missing path.
      log =
        capture_log(fn ->
          {socket, _payload} = join_lobby()

          {:ok, name} = create_test_agent(socket, "ghost-model", nil)

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
          assert model_name(info.model) == "qwen3.5-plus"
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :invalid_model for an unknown model" do
      {socket, _payload} = join_lobby()

      {:ok, name} = create_test_agent(socket, "qwen3.5-plus")

      ref =
        push(socket, "change_model", %{
          "name" => name,
          "model" => %{"name" => "totally-bogus-model"}
        })

      assert_reply ref, :error, %{"reason" => "invalid_model"}
    end

    test "returns :invalid_payload for a malformed message" do
      {socket, _payload} = join_lobby()

      ref = push(socket, "change_model", %{"name" => "no-model-field"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end
  end

  describe "init (broken_agents payload)" do
    test "sends an empty broken_agents list when persistence is disabled" do
      # Default config has `persistence_enabled: false`, so the
      # broken_agents payload is `[]`. The channel contract
      # holds either way (with or without persisted agents).
      {_socket, payload} = join_lobby()

      assert Map.has_key?(payload, :broken_agents)
      assert payload.broken_agents == []
    end

    test "init arrives immediately and the async fetch completes" do
      # The `:after_join` handler spawns the broken-agents fetch
      # in a separate process so a hung `Models.list/0` can't
      # block the channel. `list_broken_agents/0` returns `[]`
      # in this env (persistence disabled); the follow-up
      # `broken_agents_updated` lands with `[]` after the
      # `Task.async` returns.
      #
      # (We can't easily observe the stub from a spawned
      # process because `Mimic.stub` is per-process; using
      # `Mimic.set_mimic_global` would leak state across
      # tests. The follow-up-event payload is enough to
      # assert the spawn-and-collect round-trip works.)
      {_socket, payload} = join_lobby()

      assert payload.broken_agents == []
    end

    test "follow-up broken_agents_updated is pushed even when the spawned task yields []" do
      # Smaller, sleep-free regression for the empty-result
      # arm. The spawn runs `Agents.list_broken_agents/0`,
      # which short-circuits to `[]` here; the follow-up
      # event still lands with `[]`.
      {_socket, payload} = join_lobby()

      assert payload.broken_agents == []
    end

    test "dead-but-unresolvable persisted agents appear in broken_agents_updated" do
      # Regression for "agent missing from the list": the
      # `broken_agents` payload feeds `state.brokenAgents`
      # which the sidebar's "Needs Repair" section consumes.
      # The follow-up event must fire even when the underlying
      # `Agents.list_broken_agents/0` returns `[]` (here,
      # because the test config disables persistence) —
      # proving the spawn-and-relay path is intact. The
      # non-empty case requires a persisted agent whose
      # GenServer is dead; the JS sidebar test covers the
      # user-facing rendering path.
      {_socket, payload} = join_lobby()

      assert payload.broken_agents == []
    end
  end

  describe "handle_in(rescan_models)" do
    test "replies :ok immediately and broadcasts models_updated with the live catalog" do
      # The reply is `:ok` so the click handler can dismiss
      # its loading state without waiting on the auto-discovery
      # probes; the real catalog lands via the follow-up
      # `models_updated` broadcast.
      {socket, _payload} = join_lobby()

      ref = push(socket, "rescan_models", %{})
      assert_reply ref, :ok

      assert_broadcast "models_updated", %{models: models_list}, 6_000
      assert is_list(models_list)
      assert models_list != []
    end
  end

  # Creates the agent through the channel so the channel's
  # `default_vocation_id/0` fallback applies (calling
  # `Agents.create_agent/2` direct would skip it and trip
  # `agents.vocation_id NOT NULL`). `provider` defaults to
  # `"model-studio"`; pass `nil` to exercise the model-
  # missing path. Registers `AgentTestHelpers.ensure_cleanup/1`
  # so the spawned pid is fully terminated (waiting for
  # `:DOWN`) before the test exits the cleanup callback —
  # the parallel-test ownership race window is closed
  # without mailbox draining.
  defp create_test_agent(socket, model_name, provider \\ "model-studio") do
    model_attrs =
      if provider,
        do: %{"name" => model_name, "provider" => provider},
        else: %{"name" => model_name}

    ref = push(socket, "create_agent", %{"model" => model_attrs})
    assert_reply ref, :ok, %{"name" => agent_name}

    AgentTestHelpers.ensure_cleanup(agent_name)

    case Nest.Agents.Supervisor.get_agent(agent_name) do
      {:ok, agent_pid} ->
        Sandbox.allow(Repo, self(), agent_pid)

      _ ->
        :ok
    end

    {:ok, agent_name}
  end

  # The `model` field on `info` arrives as string keys for
  # agents loaded from the JSONB column (via `Persistence.
  # build_attrs_for_start/1` → `state.model`) and as atom keys
  # when the caller passes atom-keyed attrs directly. Both
  # shapes are valid in the system; tests use this accessor to
  # assert without coupling to the source shape.
  defp model_name(model), do: model[:name] || model["name"]
  defp model_provider(model), do: model[:provider] || model["provider"]

  # Join the lobby and BLOCK until the `:after_join` async
  # broken-agents fetch delivers its follow-up push. The
  # `assert_push "broken_agents_updated"` is critical: the
  # `:after_join` handler spawns a `Task.Supervisor` child
  # that does `Repo.all/1` using this test pid's sandbox
  # checkout. Without the wait, the Task outlives the test
  # pid's `Sandbox.checkin/1`, and Postgrex logs
  # "client is still using a connection from owner" on
  # DataCase teardown. Returning `{socket, init_payload}`
  # lets callers inspect the initial payload (`{socket,
  # payload} = join_lobby()`) or discard it (`{socket,
  # _payload} = join_lobby()`).
  defp join_lobby do
    {:ok, _, socket} =
      subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.LobbyChannel, "lobby")

    assert_push "init", init_payload
    assert_push "broken_agents_updated", %{broken_agents: _list}, 1_000
    {socket, init_payload}
  end
end
