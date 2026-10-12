defmodule NestWeb.LobbyChannel.ProvidersTest do
  @moduledoc """
  Tests for the LobbyChannel `providers/0` serializer and the
  `save_providers` handler.

  Runs `async: true`. Neither dependency is a global:

    * The model-cache `rescan/0` is stubbed per-test and made visible
      to the channel process with `Mimic.allow/3`, the same private-mode
      pattern the other lobby channel tests use.
    * The writer's target `local.toml` path is injected by stubbing
      `Nest.DotConfig.local_file/0`, instead of setting the
      process-global `:local_config_file` app env (which leaked the
      temp file into every concurrently-running `DotConfig.load/0`
      caller).

  Each test gets its own uniquely-named temp file, removed on exit.
  """

  use NestWeb.ChannelCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer
  alias Nest.Repo
  alias NestWeb.LobbyChannel.Providers

  setup do
    local_file =
      Path.join(System.tmp_dir!(), "providers_#{System.unique_integer([:positive])}.toml")

    Mimic.stub(Nest.DotConfig, :local_file, fn -> local_file end)
    on_exit(fn -> File.rm(local_file) end)

    {:ok, local_file: local_file}
  end

  describe "providers/0" do
    test "serializes the configured providers with string keys" do
      providers = Providers.providers()

      assert is_list(providers)
      refute Enum.empty?(providers)

      pegasus = Enum.find(providers, &(&1["name"] == "pegasus"))
      assert pegasus["base_url"] == "http://pegasus:8080/v1"
      assert pegasus["auto_models"] == true
      assert pegasus["expose_models"] == false
      assert is_list(pegasus["models"])
    end

    test "persists expose_models through the writer and re-serializes it", %{
      local_file: local_file
    } do
      providers = [
        %Provider{
          name: "exposed",
          base_url: "http://exposed.example/v1",
          api_key: "k",
          protocol: "openai",
          auto_models: false,
          tags: [],
          models: [],
          auto_probe: true,
          expose_models: true
        }
      ]

      assert :ok = Writer.save_providers(providers)

      exposed = Enum.find(Providers.providers(), &(&1["name"] == "exposed"))
      assert exposed["expose_models"] == true

      assert File.read!(local_file) =~ "expose-models"
    end

    test "reflects a freshly written local.toml" do
      # Write a provider via the writer, then confirm `providers/0`
      # surfaces it (it reads the merged base + local config).
      {:ok, config} = Nest.DotConfig.load()
      base = config.providers["model-studio"]

      providers = [
        %Provider{
          name: "brand-new",
          base_url: "https://brand-new.example/v1",
          api_key: "k",
          protocol: "openai",
          auto_models: false,
          tags: [],
          models: [],
          auto_probe: true,
          default_context_limit: base.default_context_limit
        }
      ]

      assert :ok = Writer.save_providers(providers)
      assert Enum.any?(Providers.providers(), &(&1["name"] == "brand-new"))
    end
  end

  describe "handle_in(save_providers)" do
    setup do
      Repo.delete_all(InviteSchema)
      Repo.delete_all(UserSchema)

      {:ok, user, _role} =
        Accounts.create_user(
          %{username: "providers-admin", password: "password123"},
          "first-user"
        )

      token = Accounts.AuthToken.sign(user.id)

      Process.put(:providers_admin_id, user.id)

      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

      # Drain the `:after_join` init + broken-agents pushes so later
      # `assert_receive`/`assert_reply` in each test starts from a clean
      # mailbox (assert_receive only inspects the next message).
      assert_push "init", _
      assert_push "broken_agents_updated", _

      # The handler runs in the channel process; make this test's stubs
      # (`Nest.DotConfig.local_file/0`, `Nest.Models.rescan/0`) visible
      # there.
      Mimic.allow(Nest.DotConfig, self(), socket.channel_pid)
      Mimic.allow(Nest.Models, self(), socket.channel_pid)

      {:ok, socket: socket, user: user}
    end

    test "persists the providers to local.toml and broadcasts providers_updated", %{
      socket: socket,
      local_file: local_file
    } do
      # Stub the model cache rescan so it doesn't broadcast a racy
      # `models_updated` ahead of the handler's `providers_updated`.
      # The `Mimic.allow/3` in `setup` makes the stub visible in the
      # channel process, where the handler runs.
      Mimic.expect(Nest.Models, :rescan, fn -> :ok end)

      refute File.exists?(local_file)

      ref = push(socket, "save_providers", %{"providers" => [%{"name" => "acme"}]})

      # Synchronise instead of racing the default 100 ms channel timeout: this
      # handler writes `local.toml`, parses it back through `DotConfig.load/0`
      # and broadcasts before it replies, so it is the slowest `handle_in` in
      # this file and flaked under `mix test --cover`.
      #
      # `:sys.get_state/2` is a synchronous call processed in mailbox order,
      # and the push above came from this same process, so the first barrier
      # returns only after `handle_in/3` has run — the reply is already in this
      # mailbox. The `providers_updated` broadcast is a
      # `%Phoenix.Socket.Broadcast{}` enqueued in the channel's *own* mailbox
      # while `handle_in/3` runs (`Phoenix.PubSub.broadcast/4` delivers local
      # subscribers with `send/2` from the broadcasting process), so the
      # channel forwards it to this process on its next turn — before the
      # second barrier. Both assertions below are therefore true with a `0`
      # timeout, with no timing window.
      _ = :sys.get_state(socket.channel_pid, 500)
      assert_reply ref, :ok, %{}, 0

      _ = :sys.get_state(socket.channel_pid, 500)
      assert_push "providers_updated", %{providers: providers}, 0

      assert Enum.any?(providers, &(&1["name"] == "acme"))
      assert File.exists?(local_file)
      assert File.read!(local_file) =~ "acme"
    end

    test "rejects a non-admin user with :forbidden" do
      admin_id = Process.get(:providers_admin_id)

      {:ok, _invite, invite_token} = Accounts.create_invite(admin_id)

      {:ok, bob} =
        Accounts.redeem_invite(invite_token, %{username: "bob", password: "password456"})

      bob_token = Accounts.AuthToken.sign(bob.id)

      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => bob_token})

      {:ok, _, bob_socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

      ref = push(bob_socket, "save_providers", %{"providers" => []})
      assert_reply ref, :error, %{"reason" => "forbidden"}
    end

    test "replies invalid_payload when providers is not a list", %{socket: socket} do
      ref = push(socket, "save_providers", %{"providers" => %{}})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end

    test "replies invalid_payload on a bad thinking-effort value", %{socket: socket} do
      ref =
        push(socket, "save_providers", %{
          "providers" => [%{"name" => "acme", "default_thinking_effort" => "turbo"}]
        })

      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end

    test "does not broadcast on failure", %{socket: socket} do
      ref = push(socket, "save_providers", %{"providers" => %{}})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # The handler has already returned its error reply (`assert_reply`
      # above), and a channel broadcasts before it replies — so a broadcast
      # would already be in this mailbox. No wait is needed.
      refute_push "providers_updated", _, 0
    end
  end
end
