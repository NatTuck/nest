defmodule NestWeb.LobbyChannelChangeModelTest do
  @moduledoc """
  Tests for the LobbyChannel's `change_model` handler, split
  from `NestWeb.LobbyChannelTest` to keep that file under the
  credo 500-line cap. Same setup shape — a fresh test user
  per test, authenticated via the magic-token bootstrap.
  """

  use NestWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias NestWeb.LobbyChannel

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "lobby-change-tester", password: "password123"},
        "first-user"
      )

    token = Accounts.AuthToken.sign(user.id)
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(connected, LobbyChannel, "lobby")

    {:ok, socket: socket, user: user, token: token}
  end

  # `create_test_agent` mirrors the helper in
  # `NestWeb.LobbyChannelTest` — pushed via the channel so
  # the channel's `default_vocation_id/0` fallback applies
  # (a direct `Agents.create_agent/3` would skip it and trip
  # the NOT NULL constraint on `agents.vocation_id`). Marks
  # the agent `shared: true` so the change_model handler
  # accepts edits from any owner rather than only the creator.
  defp create_test_agent(socket, model_name, provider \\ "model-studio") do
    model_attrs =
      if provider,
        do: %{"name" => model_name, "provider" => provider},
        else: %{"name" => model_name}

    # Insert a default vocation so the channel's
    # `default_vocation_id/0` fallback returns a real id.
    # The original `NestWeb.LobbyChannelTest` does this in
    # its setup; we mirror it here because this file has its
    # own setup.
    vocation_id = AgentTestHelpers.vocation_id_for_test()

    ref =
      push(socket, "create_space", %{
        "name" => "test-space-#{System.unique_integer([:positive])}",
        "model" => model_attrs,
        "shared" => true,
        "vocation_id" => vocation_id
      })

    assert_reply ref, :ok, %{"space_id" => space_id, "name" => agent_name}

    AgentTestHelpers.ensure_cleanup(agent_name)

    case Nest.Agents.Supervisor.get_agent(space_id, agent_name) do
      {:ok, agent_pid} ->
        Sandbox.allow(Repo, self(), agent_pid)

      _ ->
        :ok
    end

    {:ok, space_id, agent_name}
  end

  describe "handle_in(change_model)" do
    test "non-owner of a shared agent gets :shared_read_only", %{socket: socket, user: alice} do
      # The setup already created alice (via the magic token).
      # We need a SECOND user — Bob — to test the non-owner
      # branch.
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      # Alice shares the setup-time agent with Bob.
      vocation_id = AgentTestHelpers.vocation_id_for_test()

      ref =
        push(socket, "create_space", %{
          "name" => "test-space-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"},
          "shared" => true,
          "vocation_id" => vocation_id
        })

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name}

      AgentTestHelpers.ensure_cleanup(name)

      # Bob opens a fresh socket and tries to edit the
      # shared agent. Must be rejected with the
      # `shared_read_only` reason — Bob is authed, has
      # chat access (shared=true), but lacks ownership.
      bob_token = Accounts.AuthToken.sign(bob.id)

      {:ok, bob_conn} =
        connect(NestWeb.UserSocket, %{"token" => bob_token})

      {:ok, _, bob_socket} =
        subscribe_and_join(bob_conn, LobbyChannel, "lobby")

      bob_ref =
        push(bob_socket, "change_model", %{
          "name" => name,
          "space_id" => space_id,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply bob_ref, :error, %{"reason" => "shared_read_only"}
    end

    test "repairs an agent that started in :model_missing state", %{socket: socket} do
      # Capture the model-probe Logger.error — Agent.init/1
      # fires it when the model can't resolve. The `nil`
      # provider on the create_test_agent call forces the
      # model-missing path.
      log =
        capture_log(fn ->
          {:ok, space_id, name} = create_test_agent(socket, "ghost-model", nil)

          ref =
            push(socket, "change_model", %{
              "name" => name,
              "space_id" => space_id,
              "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
            })

          assert_reply ref, :ok, %{}

          assert_broadcast "agent:updated",
                           %{
                             "name" => ^name,
                             "model" => %{
                               "name" => "qwen3.5-plus",
                               "provider" => "model-studio"
                             }
                           },
                           200
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :invalid_model for an unknown model", %{socket: socket} do
      {:ok, space_id, name} = create_test_agent(socket, "qwen3.5-plus")

      ref =
        push(socket, "change_model", %{
          "name" => name,
          "space_id" => space_id,
          "model" => %{"name" => "totally-bogus-model"}
        })

      assert_reply ref, :error, %{"reason" => "invalid_model"}
    end

    test "returns :invalid_payload for a malformed message", %{socket: socket} do
      ref = push(socket, "change_model", %{"name" => "no-model-field"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end
  end
end
