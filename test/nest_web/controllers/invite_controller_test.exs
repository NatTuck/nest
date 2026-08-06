defmodule NestWeb.InviteControllerTest do
  @moduledoc """
  Tests for `NestWeb.InviteController` — invite issuance,
  listing, and revocation under `/api/v1/invites`.

  The `RequireAuthenticated` plug 401s anonymous requests,
  so the unauthenticated case is asserted at the top of
  every describe block.
  """

  use NestWeb.ConnCase, async: false

  import Ecto.Query

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Repo

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(Accounts.User)

    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {:ok, _invite, token} = Accounts.create_invite(alice.id)

    {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password123"})

    alice_token = AuthToken.sign(alice.id)
    bob_token = AuthToken.sign(bob.id)

    {:ok, %{alice: alice, alice_token: alice_token, bob: bob, bob_token: bob_token}}
  end

  describe "GET /api/v1/invites" do
    test "401 for anonymous requests", %{conn: conn} do
      assert json_response(conn |> get("/api/v1/invites"), 401) == %{
               "error" => "unauthenticated"
             }
    end

    test "returns the caller's invites, newest first", %{
      conn: conn,
      alice: alice,
      alice_token: token
    } do
      # Pin `inserted_at` on every invite alice owns so the
      # ordering assertion is deterministic regardless of the
      # wall clock. The setup uses the magic-token bootstrap,
      # which leaves a real `invites` row in the DB owned by
      # alice; we stamp that one too so it sorts predictably.
      t1 = ~U[2026-01-01 00:00:00Z]
      t3 = ~U[2026-01-01 00:00:02Z]

      {:ok, i1, _} = Accounts.create_invite(alice.id)
      {:ok, i2, _} = Accounts.create_invite(alice.id)

      middle = ~U[2026-01-01 00:00:01Z]

      Repo.update_all(
        from(inv in InviteSchema, where: inv.id == ^i1.id),
        set: [inserted_at: t1]
      )

      Repo.update_all(
        from(inv in InviteSchema, where: inv.id == ^i2.id),
        set: [inserted_at: t3]
      )

      # Stamp every other alice-owned invite (the
      # setup-time magic-token one, etc.) to a fixed middle
      # timestamp so the newest-first ordering is
      # deterministic regardless of wall-clock.
      Repo.update_all(
        from(inv in InviteSchema,
          where:
            inv.created_by_user_id == ^alice.id and
              inv.id != ^i1.id and inv.id != ^i2.id
        ),
        set: [inserted_at: middle]
      )

      conn = conn |> put_req_header("authorization", "Bearer #{token}") |> get("/api/v1/invites")

      body = json_response(conn, 200)
      ids = Enum.map(body["invites"], & &1["id"])

      assert List.first(ids) == i2.id
      assert i1.id in ids
    end

    test "does not leak other users' invites", %{
      conn: conn,
      bob: bob,
      alice_token: token
    } do
      # Bob creates an invite of his own; alice's GET must
      # not see it. Alice already has a setup-time invite
      # in her list — the assertion is purely "bob's invite
      # isn't in alice's response".
      {:ok, bob_invite, _} = Accounts.create_invite(bob.id)

      conn = conn |> put_req_header("authorization", "Bearer #{token}") |> get("/api/v1/invites")

      body = json_response(conn, 200)
      ids = Enum.map(body["invites"], & &1["id"])

      refute bob_invite.id in ids
    end
  end

  describe "POST /api/v1/invites" do
    test "401 for anonymous requests", %{conn: conn} do
      assert json_response(conn |> post("/api/v1/invites"), 401) == %{
               "error" => "unauthenticated"
             }
    end

    test "issues an invite and returns the plaintext token once", %{
      conn: conn,
      alice: alice,
      alice_token: token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/invites")

      body = json_response(conn, 201)
      assert is_binary(body["token"])
      assert byte_size(body["token"]) == 43
      assert body["created_by_user_id"] == alice.id

      # The token, once spent on a register, lands in `invites.token`
      # and round-trips through `Accounts.redeem_invite/2`.
      {:ok, _} =
        Accounts.redeem_invite(body["token"], %{username: "carol", password: "password123"})

      assert Accounts.user_count() == 3
    end
  end

  describe "DELETE /api/v1/invites/:id" do
    test "401 for anonymous requests", %{conn: conn, alice: alice} do
      {:ok, invite, _} = Accounts.create_invite(alice.id)

      assert json_response(conn |> delete("/api/v1/invites/#{invite.id}"), 401) == %{
               "error" => "unauthenticated"
             }
    end

    test "owner can revoke their invite", %{
      conn: conn,
      alice: alice,
      alice_token: token
    } do
      {:ok, invite, _} = Accounts.create_invite(alice.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/v1/invites/#{invite.id}")

      assert conn.status == 204
    end

    test "non-owner gets 403", %{
      conn: conn,
      alice: alice,
      bob_token: token
    } do
      {:ok, invite, _} = Accounts.create_invite(alice.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/v1/invites/#{invite.id}")

      assert json_response(conn, 403) == %{"error" => "forbidden"}
    end

    test "already-used invite returns 409", %{
      conn: conn,
      alice: alice,
      alice_token: token
    } do
      {:ok, invite, _} = Accounts.create_invite(alice.id)
      {:ok, _} = Accounts.redeem_invite(invite.token, %{username: "carol", password: "x1234567"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/v1/invites/#{invite.id}")

      assert json_response(conn, 409) == %{"error" => "already_used"}
    end

    test "unknown id returns 404", %{conn: conn, alice_token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/v1/invites/9999999")

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end
end
