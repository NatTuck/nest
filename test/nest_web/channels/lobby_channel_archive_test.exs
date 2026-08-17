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

      ref = push(socket, "archive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}
      assert_broadcast "space:archived", %{"space_id" => ^space_id}

      assert %Space{id: ^space_id, archived: true} = Spaces.get_space(space_id)
      assert Spaces.list_for_user(user.id) |> Enum.map(& &1.id) |> Enum.member?(space_id) == false
      assert Spaces.list_archived_for_user(user.id) |> Enum.map(& &1.id) == [space_id]

      ref = push(socket, "unarchive_space", %{"space_id" => space_id})
      assert_reply ref, :ok, %{}
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

      ref = push(socket, "archive_space", %{"space_id" => space_id})
      assert_reply ref, :error, %{"reason" => "forbidden"}

      ref = push(socket, "unarchive_space", %{"space_id" => space_id})
      assert_reply ref, :error, %{"reason" => "forbidden"}
    end

    test "returns not_found for a missing space" do
      {socket, _init} = join_lobby()

      ref = push(socket, "archive_space", %{"space_id" => -1})
      assert_reply ref, :error, %{"reason" => "not_found"}

      ref = push(socket, "unarchive_space", %{"space_id" => -1})
      assert_reply ref, :error, %{"reason" => "not_found"}
    end

    test "returns invalid_payload for a missing space_id" do
      {socket, _init} = join_lobby()

      # `archive_space` — no `space_id` key (pattern fails to match
      # the integer-guarded head).
      ref = push(socket, "archive_space", %{})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # `archive_space` — `space_id` present but not an integer
      # (guard fails, falls through to the catch-all head).
      ref = push(socket, "archive_space", %{"space_id" => "not-an-int"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # `unarchive_space` — no `space_id` key.
      ref = push(socket, "unarchive_space", %{})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # `unarchive_space` — `space_id` present but not an integer.
      ref = push(socket, "unarchive_space", %{"space_id" => "not-an-int"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end

    test "change_model is rejected on an archived space", %{user: user} do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user.id, %{name: "arch-change-#{System.unique_integer([:positive])}"})

      assert :ok = Spaces.archive_space(space_id)

      {socket, _init} = join_lobby()

      ref =
        push(socket, "change_model", %{
          "name" => "any-agent",
          "space_id" => space_id,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply ref, :error, %{"reason" => "space_archived"}
    end

    test "change_model on a nonexistent space returns not_found" do
      {socket, _init} = join_lobby()

      ref =
        push(socket, "change_model", %{
          "name" => "any-agent",
          "space_id" => 9_999_999,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply ref, :error, %{"reason" => "not_found"}
    end

    test "change_model on a nonexistent agent in a valid space returns not_found", %{user: user} do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user.id, %{
          name: "arch-missing-agent-#{System.unique_integer([:positive])}"
        })

      {socket, _init} = join_lobby()

      ref =
        push(socket, "change_model", %{
          "name" => "no-such-agent",
          "space_id" => space_id,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply ref, :error, %{"reason" => "not_found"}
    end
  end

  # Join the lobby and BLOCK until the `:after_join` async
  # broken-agents fetch delivers its follow-up push (mirrors the
  # canonical helper; see `LobbyChannelTest.join_lobby/0`).
  defp join_lobby do
    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Process.get(:lobby_archive_test_token)})

    {:ok, _, socket} = subscribe_and_join(connected, LobbyChannel, "lobby")

    assert_push "init", init_payload
    assert_push "broken_agents_updated", %{broken_agents: _list}, 1_000
    {socket, init_payload}
  end
end
