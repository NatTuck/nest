defmodule NestWeb.AgentChannel.JoinTest do
  @moduledoc """
  Covers the branch of `NestWeb.AgentChannel.Join` the channel tests cannot reach
  deterministically: the persisted-row fallback taken when the registry names a
  pid that has already died.

  The registry-hit path and the owner verdict are covered end-to-end by
  `NestWeb.AgentChannelTest`'s `join/3` tests. The `shared: true` half of the same
  guard is **not** covered anywhere — no agent-channel test joins a shared agent
  — so nothing here claims it; it is the same clause as the owner check, and a
  test for it would need a second agent in this space (which
  `AgentTestHelpers.start_agent/1` cannot make, since it always creates a fresh
  one).
  """

  use Nest.DataCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias NestWeb.AgentChannel.Join

  import Mimic

  setup :verify_on_exit!

  setup do
    # The magic `first-user` bootstrap token only works while the users table is
    # empty, and invites hold the FK to users.
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    :ok
  end

  describe "authorize/3" do
    # The `catch :exit` arm: the registry names a pid that is already dead, so
    # the call into it exits and the persisted row answers instead. That is a
    # real production race — the agent traps exits, so `Supervisor.stop_agent/2`
    # only queues its `:shutdown`, and the name stays registered until the
    # process is gone — so the arm must stay. Letting a real agent die to reach
    # it is a race the suite would win only sometimes; stubbing the call is the
    # deterministic way to stand in the same place.
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

      # The arm is only reachable through a *hit* on the registry, so assert the
      # setup really is the shape the test claims. Without this the test would
      # still pass if the lookup missed, having covered the other fallback
      # instead — the same mistake as a vacuous assertion.
      assert {:ok, _pid} = Nest.Agents.Registry.lookup(space_id, name)

      stub(Nest.Agents.Agent, :get_public_info, fn _pid -> exit(:noproc) end)

      # The row answers with the verdict a live agent gives: the fallback is
      # transparent, which is the property the join depends on.
      assert :ok = Join.authorize(space_id, name, alice)

      # And it is still an authorization rather than a bypass: a non-owner is
      # refused from that same row.
      {:ok, bob, :user} =
        Accounts.create_user(%{username: "bob", password: "password456"}, "member")

      assert {:error, :forbidden} = Join.authorize(space_id, name, bob)
    end
  end
end
