defmodule NestWeb.LobbyChannelEditSpaceTest do
  @moduledoc """
  The lobby's `edit_space` action: one push for a space's whole environment —
  its workspace, its network access and its sandbox backend.

  Split from `NestWeb.LobbyChannelTest` the way the other lobby subjects are
  (`change_model`, `archive`, `scoping`): one file per action, each with the
  setup it needs. What is pinned here is the channel half — the reply (the whole
  environment, because the dialog updates its cache from it), the `space:updated`
  frame another session of the same user applies, and the refusals: a payload the
  client got wrong, a space the user does not own, and a workspace the sandbox
  will not run (refused here, at the moment the user can still pick another one,
  rather than at the next agent start).
  """

  use NestWeb.ChannelCase, async: true

  import NestWeb.LobbyChannelTestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias Nest.Spaces
  alias NestWeb.LobbyChannel

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    # The channel's `default_vocation_slug/0` falls back to the first available
    # vocation; upserting is idempotent, so this cannot race another test's read.
    _ = AgentTestHelpers.vocation_id_for_test()

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "lobby-edit-space", password: "password123"},
        "first-user"
      )

    token = Accounts.AuthToken.sign(user.id)
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(connected, LobbyChannel, "lobby")

    {:ok, socket: socket, user: user}
  end

  describe "handle_in(edit_space)" do
    test "flips the space's network access and announces it", %{socket: socket} do
      ref =
        push(
          socket,
          "create_space",
          create_space_payload(%{
            "name" => "net-toggle-#{System.unique_integer([:positive])}",
            "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
          })
        )

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name}, 500
      AgentTestHelpers.ensure_cleanup(name)
      assert Spaces.get_space(space_id).network_access == true

      toggle =
        push(socket, "edit_space", %{"space_id" => space_id, "network_access" => false})

      # The reply carries the whole environment, not just the field that moved:
      # the dialog updates its cache from it.
      assert_reply toggle, :ok, reply, 500
      assert reply["network_access"] == false
      assert reply["workspace_path"] == Spaces.get_space(space_id).workspace_path
      assert reply["sandbox_backend"] == Spaces.get_space(space_id).sandbox_backend
      assert Spaces.get_space(space_id).network_access == false

      # The frame carries the whole space, so another session of the same user
      # shows the same value rather than its stale one.
      assert_push "space:updated",
                  %{"space" => %Spaces.Space{id: ^space_id, network_access: false}},
                  500

      # The live root agent is cast the same environment: allow it the checkout
      # its notice append writes through, then barrier on the cast finishing.
      {:ok, agent_pid} = Nest.Agents.Registry.lookup(space_id, name)
      Sandbox.allow(Nest.Repo, self(), agent_pid)
      # allowlist: barrier — the cast's writes must finish before the checkout goes
      _ = :sys.get_state(agent_pid)
    end

    test "refuses a payload that is not a boolean, or names no space", %{socket: socket} do
      for payload <- [
            %{"space_id" => 1, "network_access" => "yes"},
            %{"space_id" => 1},
            %{"network_access" => true},
            %{}
          ] do
        assert_reply push(socket, "edit_space", payload),
                     :error,
                     %{"reason" => "invalid_payload"},
                     500
      end
    end

    test "refuses a space the user does not own", %{socket: socket} do
      assert_reply push(socket, "edit_space", %{
                     "space_id" => -1,
                     "network_access" => false
                   }),
                   :error,
                   %{"reason" => _reason},
                   500
    end

    test "refuses a workspace the sandbox will not run, and leaves the row alone", %{
      socket: socket,
      user: user
    } do
      # Refused at the edit, not at the next agent start: this is the moment the
      # user can still pick another directory. The reply is the same code the
      # create path produces for the same path.
      {:ok, space} =
        Spaces.create_space(user.id, %{
          name: "edit-space-#{System.unique_integer([:positive])}",
          workspace_path: AgentTestHelpers.default_test_workspace()
        })

      for {path, code} <- [
            {"/tmp/not-a-workspace", "workspace_under_tmp"},
            {"/nonexistent/nest-workspace", "workspace_missing"}
          ] do
        assert_reply push(socket, "edit_space", %{
                       "space_id" => space.id,
                       "workspace_path" => path
                     }),
                     :error,
                     %{"reason" => ^code},
                     500

        assert Spaces.get_space(space.id).workspace_path == space.workspace_path
      end
    end
  end
end
