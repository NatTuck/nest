defmodule NestWeb.LobbyChannelArchiveTest do
  @moduledoc """
  Tests for the LobbyChannel's `archive_space` and
  `unarchive_space` handlers, split from `NestWeb.LobbyChannelTest`
  to keep that file under the credo 500-line cap. Same setup shape
  as `NestWeb.LobbyChannelChangeModelTest` — a fresh test user per
  test, authenticated via the magic-token bootstrap.
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
    # Clean the tables the bootstrap user depends on, mirroring
    # the canonical LobbyChannel setup.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    _ = AgentTestHelpers.create_test_space()
    _ = AgentTestHelpers.vocation_id_for_test()

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "lobby-archive-tester", password: "password123"},
        "first-user"
      )

    token = AuthToken.sign(user.id)

    Process.put(:lobby_archive_test_token, token)
    Process.put(:lobby_archive_test_user_id, user.id)

    {:ok, user: user, token: token}
  end

  describe "handle_in(archive_space) and handle_in(unarchive_space)" do
    test "archiving excludes the space from the init list and moves it to archived_spaces", %{
      user: user
    } do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user.id, %{name: "arch-lobby-#{System.unique_integer([:positive])}"})

      {socket, init} = join_lobby()

      assert Enum.any?(init.spaces, &(&1.id == space_id))
      refute Enum.any?(init.archived_spaces, &(&1.id == space_id))

      ref = push_and_settle(socket, "archive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}, 0
      assert_broadcast "space:archived", %{"space_id" => ^space_id}

      assert %Space{id: ^space_id, archived: true} = Spaces.get_space(space_id)
      assert Spaces.list_for_user(user.id) |> Enum.map(& &1.id) |> Enum.member?(space_id) == false
      assert Spaces.list_archived_for_user(user.id) |> Enum.map(& &1.id) == [space_id]

      ref = push_and_settle(socket, "unarchive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}, 0
      assert_broadcast "space:unarchived", %{"space_id" => ^space_id}

      assert %Space{id: ^space_id, archived: false} = Spaces.get_space(space_id)
    end

    test "returns forbidden for a space the user does not own", %{user: alice} do
      # A SECOND user — bob — owns the space. `Accounts.create_user`
      # with the magic `first-user` token only works when the users
      # table is empty, so we create bob via an invite/redeem instead.
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(bob.id, %{
          name: "arch-foreign-#{System.unique_integer([:positive])}"
        })

      {socket, _init} = join_lobby()

      ref = push_and_settle(socket, "archive_space", %{"space_id" => space_id})
      assert_reply ref, :error, %{"reason" => "forbidden"}, 0

      ref = push_and_settle(socket, "unarchive_space", %{"space_id" => space_id})
      assert_reply ref, :error, %{"reason" => "forbidden"}, 0
    end

    test "returns not_found for a missing space" do
      {socket, _init} = join_lobby()

      ref = push_and_settle(socket, "archive_space", %{"space_id" => -1})
      assert_reply ref, :error, %{"reason" => "not_found"}, 0

      ref = push_and_settle(socket, "unarchive_space", %{"space_id" => -1})
      assert_reply ref, :error, %{"reason" => "not_found"}, 0
    end

    test "returns invalid_payload for a missing space_id" do
      {socket, _init} = join_lobby()

      # `archive_space` — no `space_id` key (pattern fails to match
      # the integer-guarded head).
      ref = push_and_settle(socket, "archive_space", %{})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}, 0

      # `archive_space` — `space_id` present but not an integer
      # (guard fails, falls through to the catch-all head).
      ref = push_and_settle(socket, "archive_space", %{"space_id" => "not-an-int"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}, 0

      # `unarchive_space` — no `space_id` key.
      ref = push_and_settle(socket, "unarchive_space", %{})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}, 0

      # `unarchive_space` — `space_id` present but not an integer.
      ref = push_and_settle(socket, "unarchive_space", %{"space_id" => "not-an-int"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}, 0
    end

    test "change_model is rejected on an archived space", %{user: user} do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user.id, %{name: "arch-change-#{System.unique_integer([:positive])}"})

      assert :ok = Spaces.archive_space(space_id)

      {socket, _init} = join_lobby()

      ref =
        push_and_settle(socket, "change_model", %{
          "name" => "any-agent",
          "space_id" => space_id,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply ref, :error, %{"reason" => "space_archived"}, 0
    end

    test "change_model on a nonexistent space returns not_found" do
      {socket, _init} = join_lobby()

      ref =
        push_and_settle(socket, "change_model", %{
          "name" => "any-agent",
          "space_id" => 9_999_999,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply ref, :error, %{"reason" => "not_found"}, 0
    end

    test "change_model on a nonexistent agent in a valid space returns not_found", %{user: user} do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user.id, %{
          name: "arch-missing-agent-#{System.unique_integer([:positive])}"
        })

      {socket, _init} = join_lobby()

      ref =
        push_and_settle(socket, "change_model", %{
          "name" => "no-such-agent",
          "space_id" => space_id,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply ref, :error, %{"reason" => "not_found"}, 0
    end
  end

  # Join the lobby, read the `init` push, then block until the `:after_join`
  # async broken-agents fetch delivers its follow-up push.
  #
  # The `init` push needs no barrier: `subscribe_and_join/3` returns only after
  # `Phoenix.ChannelTest.join/4`'s trailing `Server.socket(pid)` — a
  # `GenServer.call/3` to the channel — and `gen_server` drains its mailbox in
  # order (`gen_server:loop/7` -> `decode_msg/9`), so that call is handled after
  # the `{:after_join, _}` self-send from `join/3`, i.e. after the channel has
  # pushed `init` to this process. `init` is already in this mailbox, so the
  # 0 ms fence below is a plain mailbox read, not a race.
  #
  # The broken-agents wait is genuinely asynchronous — a supervised `Task` doing
  # `Repo.all/1` on this test pid's sandbox checkout — so it keeps its fence.
  # Without it the Task outlives the pid's `Sandbox.checkin/1` and Postgrex logs
  # "client is still using a connection from owner".
  defp join_lobby do
    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Process.get(:lobby_archive_test_token)})

    {:ok, _, socket} = subscribe_and_join(connected, LobbyChannel, "lobby")

    assert_push "init", init_payload, 0
    assert_push "broken_agents_updated", %{broken_agents: _list}, 1_000
    {socket, init_payload}
  end

  # Push an event and return its ref only once the channel has *handled* it, so
  # the reply can be read with a non-blocking `assert_reply` 0 ms fence.
  # `gen_server` drains its mailbox in order (`gen_server:loop/7` ->
  # `decode_msg/9`), so this system message is handled only after the push — and
  # the channel sends the reply to this process before it answers the system
  # message, so the reply is already in the mailbox.
  #
  # These handlers (`archive_space` / `unarchive_space` / `change_model`) answer
  # from the database: the channel process is a sandbox proxy, so each reply
  # costs an ownership handshake plus SQL, and the 100 ms default fence is not a
  # bound on anything real. The same-shaped `chat:history` path on the agent
  # channel was measured with a rare 130-160 ms tail under the suite's 24-way
  # concurrency (see notes/test-runs/flake-*.log), so a 0 ms fence — a plain
  # mailbox read — is the honest way to await it.
  defp push_and_settle(socket, event, payload) do
    ref = push(socket, event, payload)
    _ = :sys.get_state(socket.channel_pid)
    ref
  end
end
