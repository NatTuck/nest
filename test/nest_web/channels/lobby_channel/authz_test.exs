defmodule NestWeb.LobbyChannel.AuthzTest do
  @moduledoc """
  Covers the one branch of `NestWeb.LobbyChannel.Authz` the LobbyChannel
  integration tests cannot reach deterministically: the persisted-row
  fallback taken when the registry names a pid that has already died.

  The remaining branches are covered end-to-end by the channel tests — the
  owner and shared results by `NestWeb.LobbyChannelChangeModelTest`, the
  non-owner refusal and the not-found path by
  `NestWeb.LobbyChannelArchiveTest`.
  """

  use Nest.DataCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias NestWeb.LobbyChannel.Authz

  import Mimic

  setup do
    # The magic `first-user` bootstrap token only works while the users table
    # is empty, and invites hold the FK to users.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    :ok
  end

  describe "authorize_owner_or_shared/2" do
    # The `catch :exit` arm in `fetch_visibility/2`: the registry names a pid
    # that is already dead, so the call into it exits and the persisted row
    # answers instead. That is a real production race — the agent can die
    # between `Registry.lookup/2` and `get_public_info/2` — so the arm must
    # stay. Reaching it by letting a real agent die is a race the suite would
    # win only sometimes, which is why this file's coverage of the line moved
    # with the seed; stubbing the call is the deterministic way to stand in
    # the same place.
    test "falls back to the persisted row when the registered pid is already dead" do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {_pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          created_by_user_id: alice.id,
          shared: false
        })

      space_id = AgentTestHelpers.current_space_id()

      # The arm is only reachable through a *hit* on the registry, so assert
      # the setup really is the shape the test claims. Without this the test
      # would still pass if the lookup missed, having covered the other
      # fallback instead — the same mistake as a vacuous assertion.
      assert {:ok, _pid} = Nest.Agents.Registry.lookup(space_id, name)

      stub(Nest.Agents.Agent, :get_public_info, fn _pid -> exit(:noproc) end)

      # Same answer as a live agent gives: the fallback is transparent, which
      # is the property the caller depends on.
      assert {:ok, :owner} = Authz.authorize_owner_or_shared(space_id, name, alice)
    end
  end
end
