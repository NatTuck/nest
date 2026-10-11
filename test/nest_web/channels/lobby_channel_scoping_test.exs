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

  import ExUnit.CaptureLog

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

    # A second, real user. `create_user/2` only honours the magic token when
    # the table is empty, so bob is a plain member; the multi-user cases below
    # need a user who genuinely cannot see alice's spaces.
    {:ok, bob, _role} =
      Accounts.create_user(%{username: "lobby-scoping-bob", password: "password123"}, "member")

    {:ok, user: user, token: token, alice: user, bob: bob}
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
      {socket, _payload} = join_lobby()

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

      settle(socket)
    end

    test "does NOT forward a status frame for a space the user cannot see" do
      space_id = owned_space_id()
      {socket, _payload} = join_lobby()

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

      settle(socket)
    end

    test "the frame is pushed to this client, never broadcast on the shared lobby topic" do
      space_id = owned_space_id()
      {socket, _payload} = join_lobby()

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

      settle(socket)
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

      settle(socket)
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
        {socket, _payload} = join_lobby()

        payload = Map.put(unquote(Macro.escape(payload)), "space_id", space_id)

        Phoenix.PubSub.broadcast(
          Nest.PubSub,
          "space:#{space_id}",
          {unquote(tag), payload}
        )

        assert_push unquote(event), %{"name" => "child", "space_id" => ^space_id}

        settle(socket)
      end

      test "does NOT forward #{event} for a space the user cannot see" do
        space_id = owned_space_id()
        {socket, _payload} = join_lobby()

        foreign_space_id = space_id + 1_000_000

        Phoenix.PubSub.broadcast(
          Nest.PubSub,
          "space:#{foreign_space_id}",
          {unquote(tag), %{"name" => "theirs", "space_id" => foreign_space_id}}
        )

        refute_push unquote(event), _, 200

        settle(socket)
      end

      test "does not broadcast #{event} on the shared lobby topic" do
        space_id = owned_space_id()
        {socket, _payload} = join_lobby()

        Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

        Phoenix.PubSub.broadcast(
          Nest.PubSub,
          "space:#{space_id}",
          {unquote(tag), %{"name" => "child", "space_id" => space_id}}
        )

        assert_push unquote(event), %{"name" => "child", "space_id" => ^space_id}
        refute_receive %Phoenix.Socket.Broadcast{event: unquote(event)}, 200

        settle(socket)
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

      settle(socket)
    end

    test "unarchiving a space pushes space:unarchived to this client" do
      space_id = owned_space_id()
      _ = Spaces.archive_space(space_id)
      {socket, _payload} = join_lobby()

      ref = push(socket, "unarchive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}, 500

      assert_push "space:unarchived", %{"space_id" => ^space_id}

      settle(socket)
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

      settle(socket)
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

      settle(socket)
    end
  end

  describe "unknown frames on a subscribed topic" do
    # The catch-all `handle_info/2` clause is what keeps an unrecognised frame
    # from raising a `FunctionClauseError` in the channel process and
    # disconnecting the client's lobby. It logs the frame, so each case below
    # captures and asserts on that line — both to keep the test console clean
    # (AGENTS.md) and to pin the clause's contract. The follow-up round-trip
    # goes *inside* the capture: the channel handles the frame
    # asynchronously, so asserting on the log afterwards would race the
    # emission (the same reason `Nest.Agents.Agent.InboxTest` nests its
    # assertions). `capture_log` can also pick up lines from concurrent tests,
    # so these assert on inclusion only.

    test "an unrecognised frame on the space topic is logged, and the channel survives" do
      space_id = owned_space_id()
      {socket, _payload} = join_lobby()

      # The channel subscribes to two topic families now (per-space and
      # per-user), so a frame whose tag it does not know is a live
      # possibility rather than a theoretical one.
      log =
        capture_log(fn ->
          Phoenix.PubSub.broadcast(Nest.PubSub, "space:#{space_id}", {:something_new, %{}})

          # A known frame for the same channel. It is handled after the
          # unknown one, so this push arriving proves the channel logged the
          # unknown frame and stayed up.
          Phoenix.PubSub.broadcast(
            Nest.PubSub,
            "space:#{space_id}",
            {:agent_status, %{space_id: space_id, name: "still-here", status: "idle"}}
          )

          assert_push "agent:status", %{name: "still-here"}, 500
        end)

      assert log =~ "ignoring unknown PubSub frame"
      assert log =~ ":something_new"

      settle(socket)
    end

    test "an unrecognised frame on the per-user topic is logged, and the channel survives" do
      # The space must exist before the join, so `after_join` subscribes to
      # its topic; creating it afterwards would race the reconcile.
      space_id = owned_space_id()
      {socket, _payload} = join_lobby()

      log =
        capture_log(fn ->
          Phoenix.PubSub.broadcast(
            Nest.PubSub,
            Spaces.user_topic(Process.get(:lobby_scoping_test_user_id)),
            {:not_a_frame_we_know, %{}}
          )

          Phoenix.PubSub.broadcast(
            Nest.PubSub,
            "space:#{space_id}",
            {:agent_status, %{space_id: space_id, name: "still-here", status: "idle"}}
          )

          assert_push "agent:status", %{name: "still-here"}, 500
        end)

      assert log =~ "ignoring unknown PubSub frame"
      assert log =~ ":not_a_frame_we_know"

      settle(socket)
    end
  end

  describe "multi-user scoping, real spaces (#41)" do
    # The `foreign_space_id = space_id + 1_000_000` cases above publish on a
    # topic that belongs to no space at all, so they would pass under *any*
    # subscription policy — including one that subscribed every client to
    # every real space, which is exactly the leak these changes close. These
    # cases use two real users and a real space owned by one of them. Both
    # sockets push into this test process's mailbox, so the *count* of pushes
    # is the discriminator: a second copy means the other user's channel was
    # subscribed too.

    test "user B's socket receives nothing published for user A's space", ctx do
      %{alice: alice, bob: bob} = ctx
      space = owned_space(alice)

      alice_socket = join_as(alice)
      bob_socket = join_as(bob)

      # The premise: B cannot see A's space at all.
      refute Enum.any?(Spaces.list_for_user(bob.id), &(&1.id == space.id))

      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{space.id}",
        {:agent_status, %{space_id: space.id, name: "secret", status: "streaming"}}
      )

      # A's socket gets it exactly once...
      assert_push "agent:status", %{name: "secret", status: "streaming"}, 500
      # ...and B's socket must not produce a second copy.
      refute_push "agent:status", _, 300

      # Same for an agent lifecycle frame.
      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "space:#{space.id}",
        {:agent_created, %{"name" => "secret-child", "space_id" => space.id}}
      )

      assert_push "agent:created", %{"name" => "secret-child"}, 500
      refute_push "agent:created", _, 300

      # And for a space-lifecycle frame on A's per-user topic.
      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        Spaces.user_topic(alice.id),
        {:space_created, %{"agentName" => "x", "space" => %{"id" => space.id}}}
      )

      assert_push "space:created", %{"agentName" => "x"}, 500
      refute_push "space:created", _, 300

      settle(alice_socket)
      settle(bob_socket)
    end

    test "the discriminator: two sockets' pushes share this mailbox", ctx do
      # Proof that the `refute_push`es above are real assertions rather than
      # no-ops: the "models" topic is global, so BOTH channels forward it and
      # BOTH pushes land here. If B's channel were subscribed to A's space,
      # its push would land in this same mailbox and trip the `refute_push`.
      %{alice: alice, bob: bob} = ctx

      alice_socket = join_as(alice)
      bob_socket = join_as(bob)

      Phoenix.PubSub.broadcast(Nest.PubSub, "models", {:models_updated, [%{"name" => "m1"}]})

      assert_push "models_updated", _, 500
      assert_push "models_updated", _, 500

      settle(alice_socket)
      settle(bob_socket)
    end

    test "a space created in A's session reaches B's socket not at all", ctx do
      %{alice: alice, bob: bob} = ctx

      alice_socket = join_as(alice)
      bob_socket = join_as(bob)

      ref =
        push(alice_socket, "create_space", %{
          "name" => "alice-later-#{System.unique_integer([:positive])}",
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{"name" => new_name}, 500
      AgentTestHelpers.ensure_cleanup(new_name)

      assert_push "space:created", %{"agentName" => ^new_name}, 500
      refute_push "space:created", _, 300

      # The root agent's creation frame rides the new space's topic.
      assert_push "agent:created", %{"name" => ^new_name}, 500
      refute_push "agent:created", _, 300

      settle(alice_socket)
      settle(bob_socket)
    end
  end

  # Block until the channel process has drained its mailbox, so nothing it
  # started is still in flight when this test's sandbox owner exits.
  #
  # The test process owns the SQL-sandbox connection, so when it exits, any
  # process still holding a checkout makes Postgrex log
  # `disconnected: ** (DBConnection.ConnectionError) owner #PID<…> exited` —
  # test output, which AGENTS.md forbids. Two paths do DB work from the
  # channel process after the test's last assertion: the space-set reconcile
  # (`broadcast_spaces_changed/1` -> `Spaces.list_for_user/1` and
  # `list_archived_for_user/1`), and `handle_in("create_space")`'s own
  # reconcile. `:sys.get_state/1` is a `GenServer.call`, and `gen_server`
  # drains its mailbox in order (`gen_server:loop/7` -> `decode_msg/9`), so it
  # is answered only after every frame queued before it — the same barrier
  # `NestWeb.LobbyChannelArchiveTest.push_and_settle/3` uses, applied at the
  # end of the test rather than around a single push.
  defp settle(socket), do: :sys.get_state(socket.channel_pid)

  # A real space owned by `user` — unlike the fabricated id above, this one
  # exists in the owner's visible set, so an over-broad subscription would
  # reach it.
  defp owned_space(user) do
    {:ok, %Space{} = space} =
      Spaces.create_space(user.id, %{
        name: "owned-#{System.unique_integer([:positive])}",
        slug: "owned-#{System.unique_integer([:positive])}"
      })

    space
  end

  # Join the lobby as `user`, blocking until the `:after_join` async
  # broken-agents fetch delivers its follow-up push (see `join_lobby/0`).
  defp join_as(user) do
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => AuthToken.sign(user.id)})
    {:ok, _, socket} = subscribe_and_join(connected, LobbyChannel, "lobby")

    assert_push "init", _
    assert_push "broken_agents_updated", %{broken_agents: _}, 1_000
    socket
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
