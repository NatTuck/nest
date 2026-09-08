defmodule NestWeb.LobbyChannel.ProvidersTest do
  @moduledoc """
  Tests for the LobbyChannel `providers/0` serializer and the
  `save_providers` handler.

  `async: false` because the handler (a) calls into the shared
  `Nest.Models` singleton and (b) points the writer at an
  isolated temp `local.toml` via the global `:local_config_file`
  app env — both must not race other tests.
  """

  use NestWeb.ChannelCase, async: false

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

    Application.put_env(:nest, :local_config_file, local_file)
    on_exit(fn -> File.rm(local_file) end)
    on_exit(fn -> Application.delete_env(:nest, :local_config_file) end)
    :ok
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

    test "persists expose_models through the writer and re-serializes it" do
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

      local_file = Application.get_env(:nest, :local_config_file)
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

      {:ok, socket: socket, user: user}
    end

    test "persists the providers to local.toml and broadcasts providers_updated", %{
      socket: socket
    } do
      # Stub the model cache reloads so they don't broadcast a racy
      # `models_updated` ahead of the handler's `providers_updated`.
      # Global mode is required because the handler runs in the channel
      # process, not the test process.
      Mimic.set_mimic_global()
      Mimic.expect(Nest.Models, :reload_static, fn -> :ok end)
      Mimic.expect(Nest.Models, :refresh, fn -> :ok end)

      local_file = Application.get_env(:nest, :local_config_file)
      refute File.exists?(local_file)

      ref = push(socket, "save_providers", %{"providers" => [%{"name" => "acme"}]})

      assert_reply ref, :ok
      assert_push "providers_updated", %{providers: providers}

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
      refute_push "providers_updated", _, 50
    end
  end
end
