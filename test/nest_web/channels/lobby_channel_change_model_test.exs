defmodule NestWeb.LobbyChannelChangeModelTest do
  @moduledoc """
  Tests for the LobbyChannel's `change_model` handler, split
  from `NestWeb.LobbyChannelTest` to keep that file under the
  credo 500-line cap. Same setup shape — a fresh test user
  per test, authenticated via the magic-token bootstrap.
  """

  use NestWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  import NestWeb.LobbyChannelTestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias NestWeb.LobbyChannel

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "lobby-change-tester", password: "password123"},
        "first-user"
      )

    token = Accounts.AuthToken.sign(user.id)
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(connected, LobbyChannel, "lobby")

    {:ok, socket: socket, user: user, token: token}
  end

  # `create_test_agent` mirrors the helper in
  # `NestWeb.LobbyChannelTest` — pushed via the channel so
  # the channel's `default_vocation_slug/0` fallback applies
  # (a direct `Agents.create_agent/3` would skip it and trip
  # the NOT NULL constraint on `agents.vocation_id`). Marks
  # the agent `shared: true` so the change_model handler
  # accepts edits from any owner rather than only the creator.
  defp create_test_agent(socket, model_name, provider \\ "model-studio") do
    model_attrs =
      if provider,
        do: %{"name" => model_name, "provider" => provider},
        else: %{"name" => model_name}

    # Insert a default vocation so the channel's
    # `default_vocation_slug/0` fallback returns a real id.
    # The original `NestWeb.LobbyChannelTest` does this in
    # its setup; we mirror it here because this file has its
    # own setup.
    vocation = AgentTestHelpers.vocation_slug_for_test()

    ref =
      push(
        socket,
        "create_space",
        create_space_payload(%{
          "name" => "test-space-#{System.unique_integer([:positive])}",
          "model" => model_attrs,
          "shared" => true,
          "vocation" => vocation
        })
      )

    # `assert_reply/3` defaults to a 100ms receive timeout, which is
    # too tight here. Agent creation is genuinely heavy under the
    # 64-way parallel channel-test load: the transaction spawns the
    # agent (whose `init/1` resolves context_limit via a GenServer.call
    # to the singleton `Nest.Models` plus a DotConfig TOML parse) and
    # writes the space/agent/system-message rows — all serialized
    # across parallel tests on those singletons. Wait up to 500ms for
    # the reply rather than racing a flake.
    assert_reply ref, :ok, %{"space_id" => space_id, "name" => agent_name, "slug" => _slug}, 500

    AgentTestHelpers.ensure_cleanup(agent_name)

    case Nest.Agents.Supervisor.get_agent(space_id, agent_name) do
      {:ok, agent_pid} ->
        Sandbox.allow(Repo, self(), agent_pid)

      _ ->
        :ok
    end

    {:ok, space_id, agent_name}
  end

  describe "handle_in(change_model)" do
    test "non-owner of a shared agent gets :shared_read_only", %{socket: socket, user: alice} do
      # The setup already created alice (via the magic token).
      # We need a SECOND user — Bob — to test the non-owner
      # branch.
      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      # Alice shares the setup-time agent with Bob.
      vocation = AgentTestHelpers.vocation_slug_for_test()

      ref =
        push(
          socket,
          "create_space",
          create_space_payload(%{
            "name" => "test-space-#{System.unique_integer([:positive])}",
            "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"},
            "shared" => true,
            "vocation" => vocation
          })
        )

      assert_reply ref, :ok, %{"space_id" => space_id, "name" => name, "slug" => _slug}, 500

      AgentTestHelpers.ensure_cleanup(name)

      # Bob opens a fresh socket and tries to edit the
      # shared agent. Must be rejected with the
      # `shared_read_only` reason — Bob is authed, has
      # chat access (shared=true), but lacks ownership.
      bob_token = Accounts.AuthToken.sign(bob.id)

      {:ok, bob_conn} =
        connect(NestWeb.UserSocket, %{"token" => bob_token})

      {:ok, _, bob_socket} =
        subscribe_and_join(bob_conn, LobbyChannel, "lobby")

      bob_ref =
        push(bob_socket, "change_model", %{
          "name" => name,
          "space_id" => space_id,
          "model" => %{"name" => "yolo", "provider" => "yolo"}
        })

      assert_reply bob_ref, :error, %{"reason" => "shared_read_only"}, 750
    end

    test "repairs an agent that started in :model_missing state", %{socket: socket} do
      # Capture the model-probe Logger.error — Agent.init/1
      # fires it when the model can't resolve. The `nil`
      # provider on the create_test_agent call forces the
      # model-missing path.
      log =
        capture_log(fn ->
          {:ok, space_id, name} = create_test_agent(socket, "ghost-model", nil)

          ref =
            push(socket, "change_model", %{
              "name" => name,
              "space_id" => space_id,
              "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
            })

          assert_reply ref, :ok, %{}, 750

          # #41: the frame rides the space topic and is pushed to this client.
          assert_push "agent:updated",
                      %{
                        "name" => ^name,
                        "model" => %{
                          "name" => "qwen3.5-plus",
                          "provider" => "model-studio"
                        }
                      },
                      200
        end)

      assert log =~ "could not resolve model"
    end

    test "returns :invalid_model for an unknown model", %{socket: socket} do
      {:ok, space_id, name} = create_test_agent(socket, "qwen3.5-plus")

      ref =
        push(socket, "change_model", %{
          "name" => name,
          "space_id" => space_id,
          "model" => %{"name" => "totally-bogus-model"}
        })

      assert_reply ref, :error, %{"reason" => "invalid_model"}, 750
    end

    test "returns :invalid_payload for a malformed message", %{socket: socket} do
      ref = push(socket, "change_model", %{"name" => "no-model-field"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end
  end

  # The edit's refusal payloads are pinned in
  # `NestWeb.LobbyChannel.AgentErrorsTest`, its error reply path by the
  # config-gate case below, and the `{:invalid_model, _}` reason itself by the
  # `change_model` case above — both events land in the same
  # `perform_set_model/2`. So this group needs only the success path and the
  # catch-all clause.
  describe "handle_in(edit_agent)" do
    test "edits the model and broadcasts agent:updated", %{socket: socket} do
      {:ok, space_id, name} = create_test_agent(socket, "qwen3.5-plus")

      ref =
        push(socket, "edit_agent", %{
          "name" => name,
          "space_id" => space_id,
          "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
        })

      assert_reply ref, :ok, %{}, 750

      # The `space_id` in the frame must come from the payload (the lobby
      # socket has no `space_id` in its assigns). #41: the frame rides the space
      # topic and is pushed to this client.
      #
      # No `workspace_path` in the frame: a workspace is the *space's*, so the
      # agent edit neither takes nor reports one.
      assert_push "agent:updated", %{"name" => ^name, "space_id" => ^space_id}, 200
    end

    test "returns :invalid_payload for a malformed message", %{socket: socket} do
      ref = push(socket, "edit_agent", %{"name" => "no-model-field"})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end
  end

  # Both edit handlers reach `Supervisor.get_agent/2`, so both meet the same
  # refusal: a workspace whose `.nest` is not a regular file. The reply is the
  # tagged reason (the client needs the path), and it has to be *answered* —
  # handing the tuple to `to_string/1` raises and kills the channel process, so
  # the client would get no reply at all. One test for both, because the setup
  # and the assertion are the same and only the event differs.
  describe "a workspace the config gate refuses" do
    test "both edit handlers answer with the refusal rather than killing the channel", %{
      socket: socket
    } do
      {:ok, space_id, name} = create_test_agent(socket, "qwen3.5-plus")

      ws = Repo.get!(Nest.Spaces.Space, space_id).workspace_path
      path = Path.join(ws, ".nest")
      File.write!(Path.join(ws, "real.nest"), "")
      File.ln_s!(Path.join(ws, "real.nest"), path)

      {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)
      # The channel started this agent, and it is linked to the test process, so
      # stopping it in the body would take the test down with it.
      Process.unlink(pid)

      # `stop_agent/2` only *signals*: the agent traps exits, so the `:shutdown`
      # is a message it handles when it next runs, and it is still alive (and
      # still in the Registry) when the call returns. Monitor it so the two
      # pushes below cannot race the shutdown — otherwise `get_agent/2` hands
      # back a pid that is already doomed, the call never reaches the reload path
      # that produces the refusal, and the client gets no reply at all.
      ref = Process.monitor(pid)
      :ok = Nest.Agents.Supervisor.stop_agent(space_id, name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500

      log =
        capture_log(fn ->
          for event <- ["change_model", "edit_agent"] do
            ref =
              push(socket, event, %{
                "name" => name,
                "space_id" => space_id,
                "model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}
              })

            # The channel's own process is the barrier: a `:sys` call is queued
            # behind the push, so when it returns the handler has run and its
            # reply is already in this mailbox. The refusal is reached through
            # `Supervisor.get_agent/2` → `Persistence.build_attrs_for_start/2`
            # (a DB read) and `Nest.ConfigFile.error/1` (a stat), so a bare
            # `assert_reply` could still race both. #160's flake was the queued
            # `:shutdown`, not this bound; this is the same test losing the last
            # of its clocks rather than a restatement of that diagnosis.
            # allowlist: barrier — the reply to the push above
            _ = :sys.get_state(socket.channel_pid, 1_000)

            assert_reply ref,
                         :error,
                         %{
                           "reason" => "config_file_not_regular",
                           "path" => ^path,
                           "type" => "symlink"
                         },
                         0
          end
        end)

      assert log =~ "Nest cannot protect it from being rewritten"
    end
  end
end
