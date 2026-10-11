defmodule NestWeb.LobbyChannelScopingTest do
  @moduledoc """
  Multi-user scoping tests for the LobbyChannel, split from
  `NestWeb.LobbyChannelTest` to keep that file under the credo line cap.

  Both halves of the #41 fold live here: a frame published on a *space* topic
  reaches only the clients whose user can see that space, and a space-lifecycle
  frame published on a *user* topic reaches only that user's sessions. In both
  cases the channel `push`es to its own client rather than broadcasting on the
  shared `"lobby"` topic, which every connected user is on.
  """

  use NestWeb.ChannelCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias Nest.Spaces
  alias Nest.Spaces.Space
  alias NestWeb.LobbyChannel

  setup do
    # Same bootstrap as `NestWeb.LobbyChannelTest`: a fresh test user via the
    # magic-token bootstrap, plus the tables that bootstrap depends on.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    _ = AgentTestHelpers.create_test_space()
    _ = AgentTestHelpers.vocation_id_for_test()

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "lobby-scoping-tester", password: "password123"},
        "first-user"
      )

    token = AuthToken.sign(user.id)

    Process.put(:lobby_scoping_test_token, token)
    Process.put(:lobby_scoping_test_user_id, user.id)

    {:ok, user: user, token: token}
  end

  # A space owned by the test user (`create_test_space/0` makes one with a
  # `nil` owner, which is *not* in `Spaces.list_for_user/1`). The lobby
  # channel subscribes only to the user's visible spaces, so tests about
  # delivery need a space the user actually owns.
  defp owned_space_id do
    {:ok, %Space{} = space} =
      Spaces.create_space(Process.get(:lobby_scoping_test_user_id), %{
        name: "owned-#{System.unique_integer([:positive])}",
        slug: "owned-#{System.unique_integer([:positive])}"
      })

    space.id
  end

  describe "space-scoped agent status (#53)" do
    test "forwards a status frame for a space the user can see" do
      space_id = owned_space_id()
      {_socket, _payload} = join_lobby()

      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{space_id}",
        {:agent_status, %{space_id: space_id, name: "child", status: "streaming"}}
      )

      assert_push "agent:status", %{
        space_id: ^space_id,
        name: "child",
        status: "streaming"
      }
    end

    test "does NOT forward a status frame for a space the user cannot see" do
      space_id = owned_space_id()
      {_socket, _payload} = join_lobby()

      # The channel subscribes only to the user's visible spaces
      # (`Spaces.list_for_user/1` + `list_archived_for_user/1`), so a frame
      # for someone else's space never reaches this client. That
      # subscription set is the multi-user scoping guarantee: if the channel
      # subscribed to every space, the frame below would arrive.
      foreign_space_id = space_id + 1_000_000

      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{foreign_space_id}",
        {:agent_status, %{space_id: foreign_space_id, name: "theirs", status: "streaming"}}
      )

      refute_push "agent:status", _, 200

      # ...and the frame for the user's own space still arrives, so the
      # `refute_push` above is not vacuous.
      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{space_id}",
        {:agent_status, %{space_id: space_id, name: "mine", status: "idle"}}
      )

      assert_push "agent:status", %{name: "mine", status: "idle"}
    end

    test "the frame is pushed to this client, never broadcast on the shared lobby topic" do
      space_id = owned_space_id()
      {_socket, _payload} = join_lobby()

      # The "lobby" topic is what every connected user is on. A
      # `broadcast(socket, "agent:status", …)` would fan the frame out to all
      # of them; `push(socket, …)` reaches this client only, and each of the
      # user's other sessions gets its own push from its own subscription.
      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{space_id}",
        {:agent_status, %{space_id: space_id, name: "child", status: "executing_tools"}}
      )

      assert_push "agent:status", %{name: "child", status: "executing_tools"}

      refute_receive %Phoenix.Socket.Broadcast{event: "agent:status"}, 200
    end

    test "subscribes to a space created in this session before announcing its agent" do
      {socket, _payload} = join_lobby()

      ref =
        push(socket, "create_space", %{
          "name" => "later-space-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"space_id" => new_space_id, "name" => new_name}, 500
      AgentTestHelpers.ensure_cleanup(new_name)

      # `handle_in("create_space")` reconciles synchronously before it
      # replies, so the channel is already subscribed to the new space when
      # the reply lands — a status frame for it now reaches this client.
      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{new_space_id}",
        {:agent_status, %{space_id: new_space_id, name: new_name, status: "streaming"}}
      )

      assert_push "agent:status", %{space_id: ^new_space_id, name: ^new_name}
    end
  end

  describe "space-scoped agent lifecycle (#41)" do
    # The lifecycle frames (`agent:created` / `agent:archived` /
    # `agent:updated`) used to be broadcast on the shared "lobby" topic, which
    # reached every connected user whatever space they were in. They now ride
    # the per-space topic and are forwarded to this client only.
    for {tag, event, payload} <- [
          {:agent_created, "agent:created", %{"name" => "child", "space_id" => 1}},
          {:agent_archived, "agent:archived", %{"name" => "child", "space_id" => 1}},
          {:agent_updated, "agent:updated", %{"name" => "child", "space_id" => 1}}
        ] do
      test "forwards #{event} for a space the user can see" do
        space_id = owned_space_id()
        {_socket, _payload} = join_lobby()

        payload = Map.put(unquote(Macro.escape(payload)), "space_id", space_id)

        Phoenix.PubSub.broadcast(
          Nest.PubSub,
          "space:#{space_id}",
          {unquote(tag), payload}
        )

        assert_push unquote(event), %{"name" => "child", "space_id" => ^space_id}
      end

      test "does NOT forward #{event} for a space the user cannot see" do
        space_id = owned_space_id()
        {_socket, _payload} = join_lobby()

        foreign_space_id = space_id + 1_000_000

        Phoenix.PubSub.broadcast(
          Nest.PubSub,
          "space:#{foreign_space_id}",
          {unquote(tag), %{"name" => "theirs", "space_id" => foreign_space_id}}
        )

        refute_push unquote(event), _, 200
      end

      test "does not broadcast #{event} on the shared lobby topic" do
        space_id = owned_space_id()
        {_socket, _payload} = join_lobby()

        Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

        Phoenix.PubSub.broadcast(
          Nest.PubSub,
          "space:#{space_id}",
          {unquote(tag), %{"name" => "child", "space_id" => space_id}}
        )

        assert_push unquote(event), %{"name" => "child", "space_id" => ^space_id}
        refute_receive %Phoenix.Socket.Broadcast{event: unquote(event)}, 200
      end
    end
  end

  describe "space lifecycle rides the per-user topic (#41)" do
    test "archiving a space pushes space:archived to this client" do
      space_id = owned_space_id()
      {socket, _payload} = join_lobby()

      ref = push(socket, "archive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}, 500

      assert_push "space:archived", %{"space_id" => ^space_id}

      _ = Spaces.unarchive_space(space_id)
    end

    test "unarchiving a space pushes space:unarchived to this client" do
      space_id = owned_space_id()
      _ = Spaces.archive_space(space_id)
      {socket, _payload} = join_lobby()

      ref = push(socket, "unarchive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}, 500

      assert_push "space:unarchived", %{"space_id" => ^space_id}
    end

    test "creating a space pushes space:created to this client" do
      {socket, _payload} = join_lobby()

      ref =
        push(socket, "create_space", %{
          "name" => "per-user-space-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"name" => new_name}, 500
      AgentTestHelpers.ensure_cleanup(new_name)

      assert_push "space:created",
                  %{"agentName" => ^new_name, "space" => %Nest.Spaces.Space{}}
    end

    test "does not broadcast the space frames on the shared lobby topic" do
      space_id = owned_space_id()
      {socket, _payload} = join_lobby()

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      ref = push(socket, "archive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}, 500

      assert_push "space:archived", %{"space_id" => ^space_id}
      refute_receive %Phoenix.Socket.Broadcast{event: "space:archived"}, 200

      _ = Spaces.unarchive_space(space_id)
    end
  end

  # Join the lobby and BLOCK until the `:after_join` async broken-agents fetch
  # delivers its follow-up push. The wait is critical: the spawned
  # `Task.Supervisor` child does `Repo.all/1` on this test pid's sandbox
  # checkout; without it the Task outlives the pid's `Sandbox.checkin/1` and
  # Postgrex logs "client is still using a connection from owner". Returns
  # `{socket, init_payload}`.
  defp join_lobby do
    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Process.get(:lobby_scoping_test_token)})

    {:ok, _, socket} = subscribe_and_join(connected, LobbyChannel, "lobby")

    assert_push "init", init_payload
    assert_push "broken_agents_updated", %{broken_agents: _list}, 1_000
    {socket, init_payload}
  end
end
