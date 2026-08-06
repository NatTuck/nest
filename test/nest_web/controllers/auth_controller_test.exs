defmodule NestWeb.AuthControllerTest do
  @moduledoc """
  Tests for `NestWeb.AuthController` (`/api/v1/login`,
  `/api/v1/register`, `/api/v1/logout`).

  Covers happy paths and the meaningful failure modes: bad
  credentials, missing fields, the magic `first-user` token
  rejected once users exist, invite redemption paths
  (invalid token, used token, expired token).
  """

  use NestWeb.ConnCase, async: false

  import Ecto.Query

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Repo

  setup do
    # Each test starts from an empty users + invites table so
    # the magic-token bootstrap path is reliably exercisable.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(Accounts.User)
    :ok
  end

  describe "POST /api/v1/login" do
    setup do
      {:ok, _, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      :ok
    end

    test "returns 200 + token + user on valid credentials", %{conn: conn} do
      conn =
        post(conn, "/api/v1/login", %{
          "username" => "alice",
          "password" => "password123"
        })

      assert %{"token" => token, "user" => %{"username" => "alice", "id" => id}} =
               json_response(conn, 200)

      # The returned token must round-trip back to the same user.
      assert {:ok, ^id} = AuthToken.verify(token)
    end

    test "returns 401 on a wrong password", %{conn: conn} do
      conn =
        post(conn, "/api/v1/login", %{
          "username" => "alice",
          "password" => "wrong"
        })

      assert json_response(conn, 401) == %{"error" => "invalid_credentials"}
    end

    test "returns 401 for an unknown user", %{conn: conn} do
      conn =
        post(conn, "/api/v1/login", %{
          "username" => "ghost",
          "password" => "whatever"
        })

      assert json_response(conn, 401) == %{"error" => "invalid_credentials"}
    end

    test "matches case-insensitive usernames", %{conn: conn} do
      conn =
        post(conn, "/api/v1/login", %{
          "username" => "ALICE",
          "password" => "password123"
        })

      assert %{"user" => %{"username" => "alice"}} = json_response(conn, 200)
    end

    test "returns 400 when fields are missing", %{conn: conn} do
      conn = post(conn, "/api/v1/login", %{"username" => "alice"})
      assert json_response(conn, 400) == %{"error" => "missing_fields"}
    end
  end

  describe "POST /api/v1/register" do
    test "first-user via magic token creates an admin", %{conn: conn} do
      conn =
        post(conn, "/api/v1/register", %{
          "username" => "operator",
          "password" => "password123",
          "token" => "first-user"
        })

      assert %{"token" => _token, "user" => %{"username" => "operator", "is_admin" => true}} =
               json_response(conn, 200)

      assert Accounts.user_count() == 1
    end

    test "magic token is rejected once any user exists", %{conn: conn} do
      {:ok, _, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      conn =
        post(conn, "/api/v1/register", %{
          "username" => "bob",
          "password" => "password456",
          "token" => "first-user"
        })

      assert json_response(conn, 409) == %{"error" => "users_already_exist"}
    end

    test "registers via a valid invite token", %{conn: conn} do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)

      conn =
        post(conn, "/api/v1/register", %{
          "username" => "bob",
          "password" => "password456",
          "token" => token
        })

      assert %{"token" => _, "user" => %{"username" => "bob", "is_admin" => false}} =
               json_response(conn, 200)
    end

    test "rejects an unknown invite token with 404", %{conn: conn} do
      conn =
        post(conn, "/api/v1/register", %{
          "username" => "bob",
          "password" => "password456",
          "token" => "no-such-token"
        })

      assert json_response(conn, 404) == %{"error" => "invalid_invite"}
    end

    test "rejects an already-used invite with 409", %{conn: conn} do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, _} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      conn =
        post(conn, "/api/v1/register", %{
          "username" => "carol",
          "password" => "password789",
          "token" => token
        })

      assert json_response(conn, 409) == %{"error" => "invite_already_used"}
    end

    test "rejects a revoked invite with 409", %{conn: conn} do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, invite, _} = Accounts.create_invite(alice.id)
      :ok = Accounts.revoke_invite(invite.id, alice.id)

      conn =
        post(conn, "/api/v1/register", %{
          "username" => "bob",
          "password" => "password456",
          "token" => invite.token
        })

      assert json_response(conn, 409) == %{"error" => "invite_revoked"}
    end

    test "rejects an expired invite with 409", %{conn: conn} do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, invite, _} = Accounts.create_invite(alice.id)

      Repo.update_all(
        from(i in InviteSchema, where: i.id == ^invite.id),
        set: [expires_at: ~U[2020-01-01 00:00:00Z]]
      )

      conn =
        post(conn, "/api/v1/register", %{
          "username" => "bob",
          "password" => "password456",
          "token" => invite.token
        })

      assert json_response(conn, 409) == %{"error" => "invite_expired"}
    end

    test "rejects a duplicate username with 422 + changeset errors", %{conn: conn} do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)

      conn =
        post(conn, "/api/v1/register", %{
          "username" => "ALICE",
          "password" => "password456",
          "token" => token
        })

      body = json_response(conn, 422)
      assert body["error"] == "validation_failed"
      assert body["username"] == ["has already been taken"]
    end

    test "returns 400 when fields are missing", %{conn: conn} do
      conn =
        post(conn, "/api/v1/register", %{
          "username" => "bob",
          "password" => "password456"
        })

      assert json_response(conn, 400) == %{"error" => "missing_fields"}
    end
  end

  describe "POST /api/v1/logout" do
    test "returns 204 unconditionally", %{conn: conn} do
      conn = post(conn, "/api/v1/logout", %{})
      assert conn.status == 204
    end
  end
end
