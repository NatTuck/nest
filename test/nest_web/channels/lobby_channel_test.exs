defmodule NestWeb.LobbyChannelTest do
  @moduledoc """
  Tests for the LobbyChannel.
  """
  use NestWeb.ChannelCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Repo
  alias Nest.Vocations

  # The channel's `:after_join` spawns a supervised `Task` for
  # `broken_agents`; in async mode the inner `Repo.all` raises
  # `DBConnection.OwnershipError`, rescued to `[]` (module-level
  # `capture_log` swallows the death). Setup stops leftover agent
  # pids (`Supervisor.stop_agent/1` is idempotent) before deleting
  # their DB rows, closing the parallel-test ghost-pid race window;
  # then a fresh user is created and a token signed so the socket
  # connect can authenticate.
  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()

    for name <- Nest.Persistence.list_agent_names_for_space(space_id) do
      _ = Supervisor.stop_agent(space_id, name)
      Nest.Persistence.delete_agent(space_id, name)
    end

    # The channel handler's `default_vocation_id/0` falls back
    # to the first available vocation. We don't delete the
    # table before upserting: `Vocations.upsert_vocation/1` is
    # idempotent (name-keyed), so calling it directly leaves
    # the row in the exact same state as delete-then-upsert
    # without opening a window where `Vocations.list_vocations/0`
    # returns `[]` to the channel pid's `:after_join` handler.
    _ = AgentTestHelpers.vocation_id_for_test()

    # Bootstrapping a user lets the UserSocket accept the
    # connect/3 call (which now requires a valid token).
    # Tests that want to exercise unauthenticated joins
    # should pass `nil` to `join_lobby/1`.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "lobby-tester", password: "password123"},
        "first-user"
      )

    token = AuthToken.sign(user.id)

    # Stash the token + user id so the per-test `join_lobby/0`
    # helper and the invite-related tests below can pick them
    # up without threading through every test setup.
    Process.put(:lobby_test_token, token)
    Process.put(:lobby_test_user_id, user.id)

    {:ok, %{user: user, token: token, space_id: space_id}}
  end

  describe "join/3" do
    test "returns agents, models, vocations, blueprints, and spaces on join" do
      # Connect socket and join lobby
      {_socket, payload} = join_lobby()

      # After joining, we should receive initial state
      assert is_list(payload.agents)
      assert is_list(payload.models)
      assert is_list(payload.vocations)
      assert is_list(payload.blueprints)
      assert is_list(payload.spaces)
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

  describe "init push carries invites" do
    test "returns an empty invites list when the user owns none", %{} do
      {_socket, payload} = join_lobby()

      assert is_list(payload.invites)
      assert payload.invites == []
    end

    test "returns the user's invites (active + used + revoked) sorted newest first", %{} do
      # Mint three invites for the lobby-tester user:
      # one to be redeemed, one to be revoked, one left active.
      {:ok, used_invite, used_token} =
        Accounts.create_invite(Process.get(:lobby_test_user_id))

      {:ok, revoked_invite, _} =
        Accounts.create_invite(Process.get(:lobby_test_user_id))

      {:ok, _active_invite, _} =
        Accounts.create_invite(Process.get(:lobby_test_user_id))

      :ok = Accounts.revoke_invite(revoked_invite.id, Process.get(:lobby_test_user_id))
      {:ok, _} = Accounts.redeem_invite(used_token, %{username: "carol", password: "password123"})

      {_socket, payload} = join_lobby()

      assert is_list(payload.invites)
      assert length(payload.invites) == 3

      ids = Enum.map(payload.invites, & &1.id)
      # Every invite owned by the test user shows up —
      # active, used, and revoked alike.
      assert used_invite.id in ids
      assert revoked_invite.id in ids

      # The token is included so the UI can render a copy
      # button on every row.
      for invite <- payload.invites do
        assert is_binary(invite.token)
        assert byte_size(invite.token) == 43
      end
    end
  end

  describe "handle_in(create_invite)" do
    test "issues an invite and pushes invite:created on success" do
      {socket, _payload} = join_lobby()

      ref = push(socket, "create_invite", %{})

      assert_reply ref, :ok, public
      assert is_integer(public.id)
      assert is_binary(public.token)
      assert byte_size(public.token) == 43
      assert public.created_by_user_id == Process.get(:lobby_test_user_id)

      # The server also pushes invite:created to this socket
      # so the in-memory list updates without re-fetching.
      assert_push "invite:created", pushed
      assert pushed.id == public.id
      assert pushed.token == public.token
    end

    test "returns :too_many_invites error after 10 invites" do
      # Mint 10 invites for the test user; the 11th must
      # hit the cap and reply with the `too_many_invites`
      # error string.
      for _ <- 1..10 do
        {:ok, _, _} = Accounts.create_invite(Process.get(:lobby_test_user_id))
      end

      {socket, _payload} = join_lobby()

      ref = push(socket, "create_invite", %{})

      assert_reply ref, :error, %{error: "too_many_invites"}
    end
  end

  describe "handle_in(revoke_invite)" do
    test "owner can revoke their own invite" do
      {socket, _payload} = join_lobby()

      {:ok, invite, _} =
        Accounts.create_invite(Process.get(:lobby_test_user_id))

      ref = push(socket, "revoke_invite", %{"id" => invite.id})
      assert_reply ref, :ok

      assert_push "invite:revoked", pushed
      assert pushed.id == invite.id
    end

    test "non-owner receives the :forbidden error" do
      # Mint an invite owned by a different user; the
      # lobby-tester cannot revoke it. Use a real invite
      # (the magic `first-user` token was already spent on
      # the test setup's bootstrap user).
      {:ok, _invite, raw_token} =
        Accounts.create_invite(Process.get(:lobby_test_user_id))

      {:ok, alice} =
        Accounts.redeem_invite(raw_token, %{username: "alice-other", password: "password123"})

      {:ok, invite, _} = Accounts.create_invite(alice.id)

      {socket, _payload} = join_lobby()

      ref = push(socket, "revoke_invite", %{"id" => invite.id})
      assert_reply ref, :error, %{error: "forbidden"}
    end

    test "invalid id returns :invalid_id" do
      {socket, _payload} = join_lobby()

      ref = push(socket, "revoke_invite", %{"id" => "not-a-number"})
      assert_reply ref, :error, %{error: "invalid_id"}
    end
  end

  describe "handle_in(create_space)" do
    test "creates space (with root agent) and broadcasts event" do
      {socket, _payload} = join_lobby()

      ref =
        push(socket, "create_space", %{
          "name" => "test-space-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name}
      assert Regex.match?(~r/^[a-z0-9-]+$/, name)

      # Register cleanup for the push-created agent so the
      # singleton `Nest.Agents.Supervisor` doesn't carry a
      # ghost pid into subsequent parallel tests — and so
      # the agent's mailbox can't fire DB calls after this
      # test has exited its sandbox checkout.
      AgentTestHelpers.ensure_cleanup(name)

      assert_broadcast "agent:created", %{
        "name" => ^name,
        "space_id" => ^space_id,
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
        push(socket, "create_space", %{
          "name" => "test-space-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name}
      AgentTestHelpers.ensure_cleanup(name)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert model_name(info.model) == "qwen3.5-plus"
      assert model_provider(info.model) == "model-studio"

      assert_broadcast "agent:created", %{
        "name" => ^name,
        "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
      }
    end

    test "blueprint_id drives the root agent's vocation over the default" do
      # Phase 2: when the client picks a blueprint, the lobby must
      # NOT forward its default `vocation_id` fallback, so the
      # root agent's vocation comes from the blueprint's
      # `root_vocation_id`.
      vocation =
        Vocations.upsert_vocation(%{
          name: "lobby-blueprint-voc-#{System.unique_integer([:positive])}",
          description: "Blueprint root vocation",
          system_prompt: "You are the blueprint root.",
          tools: [],
          modes: %{}
        })
        |> elem(1)

      blueprint =
        Blueprints.upsert_blueprint(%{
          name: "lobby-blueprint-#{System.unique_integer([:positive])}",
          root_vocation_id: vocation.id
        })
        |> elem(1)

      {socket, _payload} = join_lobby()

      ref =
        push(socket, "create_space", %{
          "name" => "blueprint-space-#{System.unique_integer([:positive])}",
          "blueprint_id" => blueprint.id,
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name}
      AgentTestHelpers.ensure_cleanup(name)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.vocation_id == vocation.id
    end
  end

  describe "handle_in(delete_agent)" do
    test "deletes agent and broadcasts event" do
      {socket, _payload} = join_lobby()

      # Create via the channel so the channel's
      # `default_vocation_id/0` fallback applies.
      # `Agents.create_agent/3` direct would skip that and
      # trip the NOT NULL constraint on `agents.vocation_id`.
      ref =
        push(socket, "create_space", %{
          "name" => "test-space-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name}

      ref = push(socket, "delete_agent", %{"name" => name, "space_id" => space_id})
      assert_reply ref, :ok, %{}
      assert_broadcast "agent:deleted", %{"name" => ^name, "space_id" => _}

      # Verify agent is gone
      assert {:error, :not_found} = Agents.get_info(space_id, name)
    end

    test "returns error for non-existent agent" do
      # Connect socket and join lobby
      {socket, _payload} = join_lobby()
      space_id = AgentTestHelpers.current_space_id()

      ref = push(socket, "delete_agent", %{"name" => "nonexistent", "space_id" => space_id})
      assert_reply ref, :error, %{"reason" => "not_found"}
    end
  end

  describe "handle_in(suggest_space_name)" do
    test "replies with a non-empty adjective-animal space name" do
      {socket, _payload} = join_lobby()

      ref = push(socket, "suggest_space_name", %{})
      assert_reply ref, :ok, %{"name" => name}
      assert name =~ "-" and name != ""
    end
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
  # broken-agents fetch delivers its follow-up push. The wait
  # is critical: the spawned `Task.Supervisor` child does
  # `Repo.all/1` on this test pid's sandbox checkout; without
  # it the Task outlives the pid's `Sandbox.checkin/1` and
  # Postgrex logs "client is still using a connection from
  # owner". Returns `{socket, init_payload}`.
  defp join_lobby do
    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Process.get(:lobby_test_token)})

    {:ok, _, socket} =
      subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    assert_push "init", init_payload
    assert_push "broken_agents_updated", %{broken_agents: _list}, 1_000
    {socket, init_payload}
  end
end
