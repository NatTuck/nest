defmodule Nest.AccountsTest do
  @moduledoc """
  Tests for `Nest.Accounts`: user lifecycle, authentication,
  invite creation/redeem/revoke, and the magic `first-user`
  bootstrap path.

  Every test exercises the database (sandboxed by `DataCase`).
  Each async test gets its own sandbox transaction, so the
  `user_count() == 0` bootstrap assertions see an isolated,
  empty table — no serialization is needed.
  """

  use Nest.DataCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Repo

  setup do
    # Belt-and-braces: clear any rows visible to this test's
    # sandbox transaction so the bootstrap magic-token path is
    # deterministically exercisable.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)
    :ok
  end

  describe "user_count/0" do
    test "returns 0 with no users, and the count after users exist" do
      assert Accounts.user_count() == 0

      {:ok, alice, :admin} = Accounts.create_user(registration_attrs("alice"), "first-user")
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, _bob} = Accounts.redeem_invite(token, registration_attrs("bob"))

      assert Accounts.user_count() == 2
    end
  end

  describe "create_user/2" do
    test "creates the first user via the magic token, then rejects it" do
      assert {:ok, %UserSchema{is_admin: true}, :admin} =
               Accounts.create_user(registration_attrs("alice"), "first-user")

      assert Accounts.user_count() == 1

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

    test "caps the username at the shared byte limit, not a character count" do
      # `Nest.Name` says 255 bytes for an agent's name and a human's username
      # alike; the changeset reads the cap from there rather than keeping a
      # second, character-based limit that a migrated name could fall outside.
      at_cap = String.duplicate("a", Nest.Name.max_bytes())
      over = String.duplicate("a", Nest.Name.max_bytes() + 1)

      assert UserSchema.registration_changeset(%UserSchema{}, %{username: at_cap}).valid?

      changeset = UserSchema.registration_changeset(%UserSchema{}, %{username: over})

      refute changeset.valid?
      assert %{username: ["should be at most 255 byte(s)"]} = errors_on(changeset)
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

    test "returns the user on a valid password, case-insensitively", %{user: user} do
      assert {:ok, %UserSchema{id: id}} = Accounts.authenticate("alice", "password123")
      assert id == user.id

      assert {:ok, %UserSchema{id: id}} = Accounts.authenticate("ALICE", "password123")
      assert id == user.id
    end

    test "matches the shared fold, not just case", %{user: alice} do
      # `registration_changeset/2` stores `Nest.Name.sanitize/1`, which folds
      # punctuation as well as case. Reading with a plain trim+downcase would
      # look up `"jane doe"` for a stored `"jane-doe"` and lock this user out —
      # and the migration would have rewritten a `"Jane Doe"` login that worked
      # before it ran.
      {:ok, _invite, token} = Accounts.create_invite(alice.id)

      {:ok, %UserSchema{} = jane} =
        Accounts.redeem_invite(
          token,
          Map.put(registration_attrs(""), :username, "Jane Doe")
        )

      assert jane.username == "jane-doe"

      for username <- ["Jane Doe", "jane-doe", "Jane.Doe", "JANE-DOE"] do
        assert {:ok, %UserSchema{id: id}} = Accounts.authenticate(username, "password123")
        assert id == jane.id
      end
    end

    test "returns :invalid_credentials for a wrong password or an unknown username" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("alice", "wrong-password")

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

  describe "get_user_by_username/1" do
    test "resolves a username the way an address writes it" do
      # The resolution behind `Nest.Notes.deliver/5`'s `:user` addressee: an
      # address names a user, and this is the one place that decides whether it
      # names one. The fold is `Nest.Name`'s — the rule a username is *stored*
      # by — so `@Nat` and `@nat` are one lookup and a caller never has to know.
      {:ok, alice, :admin} = Accounts.create_user(registration_attrs("Jane Doe"), "first-user")

      assert %UserSchema{id: id} = Accounts.get_user_by_username("jane-doe")
      assert id == alice.id
      assert %UserSchema{id: ^id} = Accounts.get_user_by_username("Jane Doe")
      assert %UserSchema{id: ^id} = Accounts.get_user_by_username("JANE-DOE")

      # Nothing, for a name nobody has — including the two shapes that fold to
      # no name at all.
      assert Accounts.get_user_by_username("bob") == nil
      assert Accounts.get_user_by_username("") == nil
      assert Accounts.get_user_by_username("...") == nil
      assert Accounts.get_user_by_username(nil) == nil
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

    test "returns nil for a tampered, malformed, or nil/empty token", %{token: token} do
      # Flip a character somewhere in the middle of the token.
      <<head::binary-size(10), char, rest::binary>> = token
      flipped = if char == ?a, do: ?b, else: ?a
      tampered = head <> <<flipped>> <> rest
      assert Accounts.get_user_by_token(tampered) == nil

      assert Accounts.get_user_by_token("not-a-token") == nil
      assert Accounts.get_user_by_token(nil) == nil
      assert Accounts.get_user_by_token("") == nil
    end

    test "returns nil when the underlying user no longer exists", %{user: alice} do
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, transient} = Accounts.redeem_invite(token, registration_attrs("bob"))
      signed = AuthToken.sign(transient.id)
      Repo.delete!(transient)

      assert Accounts.get_user_by_token(signed) == nil
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

    test "redeem_invite succeeds, then rejects unknown or used tokens", %{raw_token: token} do
      assert {:ok, %UserSchema{username: "bob"}} =
               Accounts.redeem_invite(token, registration_attrs("bob"))

      assert {:error, :invalid_token} =
               Accounts.redeem_invite("not-a-token", registration_attrs("bob"))

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

    test "owner revokes; a non-owner is forbidden and an unknown id is not found", %{
      alice: alice,
      bob: bob,
      invite: invite
    } do
      assert {:error, :not_found} = Accounts.revoke_invite(99_999, alice.id)
      assert {:error, :forbidden} = Accounts.revoke_invite(invite.id, bob.id)
      assert :ok = Accounts.revoke_invite(invite.id, alice.id)
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

    test "allows 10 invites, then rejects the 11th without inserting a row", %{alice: alice} do
      for n <- 1..10 do
        assert {:ok, _, _} = Accounts.create_invite(alice.id),
               "create_invite/1 failed at invite #{n}"
      end

      before_count = Accounts.count_user_invites(alice.id)

      assert {:error, :too_many_invites} = Accounts.create_invite(alice.id)

      assert Accounts.count_user_invites(alice.id) == before_count
    end
  end

  describe "count_user_invites/1" do
    test "counts 0 with no invites, then active, used, and revoked together" do
      {:ok, alice, _} = Accounts.create_user(registration_attrs("alice"), "first-user")

      assert Accounts.count_user_invites(alice.id) == 0

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
      # doesn't depend on the wall clock — three `create_invite/1`
      # calls land microseconds apart, which is an accident, not a
      # contract.
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
