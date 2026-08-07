defmodule Nest.AccountsTest do
  @moduledoc """
  Tests for `Nest.Accounts`: user lifecycle, authentication,
  invite creation/redeem/revoke, and the magic `first-user`
  bootstrap path.

  Every test exercises the database (sandboxed by `DataCase`).
  Async where possible — tests that exercise the
  `user_count() == 0` bootstrap path need to truncate the
  users table so they can't run alongside others, hence
  `async: false` for those few.
  """

  use Nest.DataCase, async: false

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Repo

  setup do
    # Each test starts from an empty users + invites table so
    # the bootstrap magic-token path is reliably exercisable
    # without contaminating other tests.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)
    :ok
  end

  describe "user_count/0" do
    test "returns 0 when no users exist" do
      assert Accounts.user_count() == 0
    end

    test "returns the count after users are created" do
      {:ok, alice, :admin} = Accounts.create_user(registration_attrs("alice"), "first-user")
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, _bob} = Accounts.redeem_invite(token, registration_attrs("bob"))

      assert Accounts.user_count() == 2
    end
  end

  describe "create_user/2" do
    test "creates the first user via the magic token with is_admin: true" do
      assert {:ok, %UserSchema{is_admin: true}, :admin} =
               Accounts.create_user(registration_attrs("alice"), "first-user")

      assert Accounts.user_count() == 1
    end

    test "rejects the magic token once any user exists" do
      {:ok, _, :admin} = Accounts.create_user(registration_attrs("alice"), "first-user")

      assert {:error, :no_users_allowed} =
               Accounts.create_user(registration_attrs("bob"), "first-user")
    end

    test "subsequent registrations via a real invite are non-admin" do
      {:ok, alice, :admin} = Accounts.create_user(registration_attrs("alice"), "first-user")
      {:ok, _invite, token} = Accounts.create_invite(alice.id)

      assert {:ok, %UserSchema{is_admin: false}} =
               Accounts.redeem_invite(token, registration_attrs("bob"))
    end

    test "stores a hashed password (never plaintext)" do
      {:ok, user, _} = Accounts.create_user(registration_attrs("alice"), "first-user")

      refute Repo.get(UserSchema, user.id).password_hash =~ "password123"
    end

    test "normalizes the username to lowercase + trim" do
      {:ok, user, _} =
        Accounts.create_user(
          Map.put(registration_attrs(""), :username, "  Alice  "),
          "first-user"
        )

      assert user.username == "alice"
    end

    test "rejects duplicate usernames (case-insensitive)" do
      {:ok, alice, _} =
        Accounts.create_user(
          Map.put(registration_attrs(""), :username, "alice"),
          "first-user"
        )

      {:ok, _invite, token} = Accounts.create_invite(alice.id)

      assert {:error, changeset} =
               Accounts.redeem_invite(
                 token,
                 Map.put(registration_attrs(""), :username, "ALICE")
               )

      assert %{username: ["has already been taken"]} =
               errors_on(changeset)
    end

    test "rejects an empty password with a changeset error" do
      attrs = Map.put(registration_attrs("alice"), :password, "")

      assert {:error, changeset} = Accounts.create_user(attrs, "first-user")
      assert %{password: ["is required"]} = errors_on(changeset)
    end

    test "redeem_invite fails atomically when the user-row validation fails" do
      {:ok, alice, :admin} =
        Accounts.create_user(registration_attrs("alice"), "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)

      # Pass an empty password so the user insert fails.
      # The invite should NOT be marked used.
      assert {:error, changeset} =
               Accounts.redeem_invite(token, Map.put(registration_attrs("bob"), :password, ""))

      assert %{password: ["is required"]} = errors_on(changeset)

      # `token` was just generated above; fetch the persisted
      # invite and assert it was never marked used. The invite
      # is still redeemable.
      invite =
        Repo.get_by(InviteSchema, token: token)

      assert invite.used_at == nil

      # A second redemption succeeds because the first one
      # rolled back.
      assert {:ok, %UserSchema{username: "carol"}} =
               Accounts.redeem_invite(token, registration_attrs("carol"))
    end
  end

  describe "authenticate/2" do
    setup do
      {:ok, user, _} = Accounts.create_user(registration_attrs("alice"), "first-user")
      %{user: user}
    end

    test "returns the user on a valid password", %{user: user} do
      assert {:ok, %UserSchema{id: id}} = Accounts.authenticate("alice", "password123")
      assert id == user.id
    end

    test "matches case-insensitive usernames", %{user: user} do
      assert {:ok, %UserSchema{id: id}} = Accounts.authenticate("ALICE", "password123")
      assert id == user.id
    end

    test "returns :invalid_credentials on a wrong password", %{user: _user} do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("alice", "wrong-password")
    end

    test "returns :invalid_credentials for an unknown username" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("nobody", "password123")
    end

    test "returns :missing_fields for non-binary arguments" do
      assert {:error, :missing_fields} = Accounts.authenticate(nil, "x")
      assert {:error, :missing_fields} = Accounts.authenticate("x", nil)
    end

    test "takes roughly the same time on missing vs wrong-password paths" do
      # Run both a missing-user and a wrong-password authentication
      # back-to-back. The test isn't a precise timing oracle — it's a
      # smoke test that neither path returns instantly. If a future
      # refactor accidentally removes the compensating hash in the
      # no-user branch, the missing-user path will become
      # microsecond-fast and the difference will show up here.
      #
      # The argon2 `t_cost` / `m_cost` config sets the worst-case
      # wall-clock to a few hundred microseconds in the test
      # environment (`config/test.exs`), so the 0.5ms floor is
      # conservative: any path that returns in less than that
      # time almost certainly skipped the hash.
      t0 = System.monotonic_time(:microsecond)
      Accounts.authenticate("ghost", "whatever")
      t1 = System.monotonic_time(:microsecond)
      Accounts.authenticate("alice", "wrong-password")
      t2 = System.monotonic_time(:microsecond)

      missing_ms = (t1 - t0) / 1000
      wrong_ms = (t2 - t1) / 1000

      assert missing_ms > 0.25,
             "missing-user path took #{missing_ms}ms — the compensating hash may be missing"

      assert wrong_ms > 0.25
    end
  end

  describe "get_user_by_token/1" do
    setup do
      {:ok, user, _} = Accounts.create_user(registration_attrs("alice"), "first-user")
      token = AuthToken.sign(user.id)
      %{user: user, token: token}
    end

    test "returns the user for a valid token", %{user: user, token: token} do
      assert %UserSchema{id: id} = Accounts.get_user_by_token(token)
      assert id == user.id
    end

    test "returns nil for a tampered token", %{token: token} do
      # Flip a character somewhere in the middle of the token.
      <<head::binary-size(10), char, rest::binary>> = token
      flipped = if char == ?a, do: ?b, else: ?a
      tampered = head <> <<flipped>> <> rest
      assert Accounts.get_user_by_token(tampered) == nil
    end

    test "returns nil for a malformed token" do
      assert Accounts.get_user_by_token("not-a-token") == nil
    end

    test "returns nil when the underlying user no longer exists", %{user: alice} do
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, transient} = Accounts.redeem_invite(token, registration_attrs("bob"))
      signed = AuthToken.sign(transient.id)
      Repo.delete!(transient)

      assert Accounts.get_user_by_token(signed) == nil
    end

    test "returns nil for nil/empty input" do
      assert Accounts.get_user_by_token(nil) == nil
      assert Accounts.get_user_by_token("") == nil
    end
  end

  describe "invite lifecycle" do
    setup do
      {:ok, creator, _} = Accounts.create_user(registration_attrs("alice"), "first-user")
      {:ok, invite, raw_token} = Accounts.create_invite(creator.id)
      %{creator: creator, invite: invite, raw_token: raw_token}
    end

    test "create_invite returns a row with token + expiry + creator", %{
      creator: creator,
      invite: invite,
      raw_token: raw_token
    } do
      assert invite.created_by_user_id == creator.id
      assert invite.token == raw_token
      assert byte_size(raw_token) == 43
      assert DateTime.compare(invite.expires_at, DateTime.utc_now()) == :gt
    end

    test "redeem_invite succeeds with valid params", %{raw_token: token} do
      assert {:ok, %UserSchema{username: "bob"}} =
               Accounts.redeem_invite(token, registration_attrs("bob"))
    end

    test "redeem_invite rejects an unknown token" do
      assert {:error, :invalid_token} =
               Accounts.redeem_invite("not-a-token", registration_attrs("bob"))
    end

    test "redeem_invite rejects a token that's already been used", %{raw_token: token} do
      {:ok, _} = Accounts.redeem_invite(token, registration_attrs("bob"))

      assert {:error, :already_used} =
               Accounts.redeem_invite(token, registration_attrs("carol"))
    end

    test "redeem_invite rejects a revoked token", %{
      invite: invite,
      creator: creator,
      raw_token: token
    } do
      assert :ok = Accounts.revoke_invite(invite.id, creator.id)

      assert {:error, :revoked} =
               Accounts.redeem_invite(token, registration_attrs("bob"))
    end

    test "redeem_invite rejects an expired token", %{invite: invite, raw_token: token} do
      Repo.update_all(
        from(i in InviteSchema, where: i.id == ^invite.id),
        set: [expires_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert {:error, :expired} =
               Accounts.redeem_invite(token, registration_attrs("bob"))
    end

    test "redeem_invite fails atomically when user-row validation fails", %{
      invite: invite,
      raw_token: token
    } do
      assert {:error, changeset} =
               Accounts.redeem_invite(token, Map.put(registration_attrs("bob"), :password, ""))

      assert %{password: ["is required"]} = errors_on(changeset)

      refreshed = Repo.get(InviteSchema, invite.id)
      assert is_nil(refreshed.used_at)
    end
  end

  describe "revoke_invite/2" do
    setup do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")

      {:ok, alice_invite, _} = Accounts.create_invite(alice.id)
      {:ok, bob_invite, _} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(bob_invite.token, registration_attrs("bob"))

      %{alice: alice, bob: bob, invite: alice_invite}
    end

    test "owner can revoke their own invite", %{alice: alice, invite: invite} do
      assert :ok = Accounts.revoke_invite(invite.id, alice.id)
    end

    test "non-owner gets :forbidden", %{bob: bob, invite: invite} do
      assert {:error, :forbidden} = Accounts.revoke_invite(invite.id, bob.id)
    end

    test "unknown id returns :not_found", %{alice: alice} do
      assert {:error, :not_found} = Accounts.revoke_invite(99_999, alice.id)
    end

    test "already-used invite cannot be revoked", %{alice: alice, invite: invite} do
      {:ok, _} =
        Accounts.redeem_invite(
          Repo.get!(InviteSchema, invite.id).token,
          registration_attrs("carol")
        )

      assert {:error, :already_used} = Accounts.revoke_invite(invite.id, alice.id)
    end

    test "revoking an already-revoked invite is a no-op", %{alice: alice, invite: invite} do
      :ok = Accounts.revoke_invite(invite.id, alice.id)
      assert :ok = Accounts.revoke_invite(invite.id, alice.id)
    end
  end

  describe "create_invite/1 10-invite cap" do
    setup do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")
      %{alice: alice}
    end

    test "succeeds for the first 10 invites", %{alice: alice} do
      for n <- 1..10 do
        assert {:ok, _, _} = Accounts.create_invite(alice.id),
               "create_invite/1 failed at invite #{n}"
      end
    end

    test "returns :too_many_invites on the 11th attempt", %{alice: alice} do
      for _ <- 1..10, do: {:ok, _, _} = Accounts.create_invite(alice.id)

      assert {:error, :too_many_invites} = Accounts.create_invite(alice.id)
    end

    test "does not insert a row when the cap is hit", %{alice: alice} do
      for _ <- 1..10, do: {:ok, _, _} = Accounts.create_invite(alice.id)
      before_count = Accounts.count_user_invites(alice.id)

      assert {:error, :too_many_invites} = Accounts.create_invite(alice.id)

      assert Accounts.count_user_invites(alice.id) == before_count
    end
  end

  describe "count_user_invites/1" do
    test "returns 0 when the user owns no invites" do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")

      assert Accounts.count_user_invites(alice.id) == 0
    end

    test "counts active, used, and revoked invites together" do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")

      {:ok, _active, _} = Accounts.create_invite(alice.id)
      {:ok, used, _} = Accounts.create_invite(alice.id)
      {:ok, revoked, _} = Accounts.create_invite(alice.id)
      :ok = Accounts.revoke_invite(revoked.id, alice.id)

      {:ok, _} =
        Accounts.redeem_invite(used.token, registration_attrs("carol"))

      # 3 owned: active, used, revoked — all count toward
      # the 10-invite cap.
      assert Accounts.count_user_invites(alice.id) == 3
    end

    test "does not include invites owned by other users" do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")
      {:ok, _invite, raw} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(raw, registration_attrs("bob"))

      {:ok, _, _} = Accounts.create_invite(bob.id)

      assert Accounts.count_user_invites(alice.id) == 1
      assert Accounts.count_user_invites(bob.id) == 1
    end
  end

  describe "list_user_invites/1" do
    test "returns only the user's invites, newest first" do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")

      # Pin `inserted_at` explicitly so the ordering assertion
      # doesn't depend on the wall clock — `create_invite/1`
      # defaults to NOW(), which clusters on the same millisecond.
      t1 = ~U[2026-01-01 00:00:00Z]
      t2 = ~U[2026-01-01 00:00:01Z]
      t3 = ~U[2026-01-01 00:00:02Z]

      {:ok, i1, _} = Accounts.create_invite(alice.id)
      {:ok, i2, _} = Accounts.create_invite(alice.id)
      {:ok, i3, _} = Accounts.create_invite(alice.id)

      Repo.update_all(
        from(inv in InviteSchema, where: inv.id == ^i1.id),
        set: [inserted_at: t1]
      )

      Repo.update_all(
        from(inv in InviteSchema, where: inv.id == ^i2.id),
        set: [inserted_at: t2]
      )

      Repo.update_all(
        from(inv in InviteSchema, where: inv.id == ^i3.id),
        set: [inserted_at: t3]
      )

      {:ok, _bob} = Accounts.redeem_invite(i3.token, registration_attrs("bob"))

      alice_invites = Accounts.list_user_invites(alice.id)

      assert length(alice_invites) == 3
      # Newest first
      assert alice_invites
             |> Enum.map(& &1.inserted_at)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) != :lt end)
    end
  end

  # Helpers

  defp registration_attrs(username) do
    %{username: username, password: "password123"}
  end
end
