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
      assert pegasus["probe_multimodal"] == false
      assert is_list(pegasus["models"])
    end

    test "persists expose_models and probe_multimodal through the writer and re-serializes them",
         %{local_file: local_file} do
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
          expose_models: true,
          probe_multimodal: true
        }
      ]

      assert :ok = Writer.save_providers(providers)

      exposed = Enum.find(Providers.providers(), &(&1["name"] == "exposed"))
      assert exposed["expose_models"] == true
      assert exposed["probe_multimodal"] == true

      toml = File.read!(local_file)
      assert toml =~ "expose-models"
      assert toml =~ "probe-multimodal"
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

      # This handler writes `local.toml`, parses it back through
      # `DotConfig.load/0` and broadcasts before it replies, so it is the
      # slowest `handle_in` in this file and flaked under `mix test --cover`.
      # The reply and the `providers_updated` push are the events that decide
      # these two assertions: each carries its own real bound, rather than
      # synchronising on the channel process to read them with a `0` fence.
      assert_reply ref, :ok, %{}, 1_000
      assert_push "providers_updated", %{providers: providers}, 1_000

      assert Enum.any?(providers, &(&1["name"] == "acme"))
      assert File.exists?(local_file)
      assert File.read!(local_file) =~ "acme"
    end

    test "round-trips probe_multimodal through save, the push and local.toml", %{
      socket: socket,
      local_file: local_file
    } do
      Mimic.expect(Nest.Models, :rescan, fn -> :ok end)

      ref =
        push(socket, "save_providers", %{
          "providers" => [
            %{"name" => "opted-in", "probe_multimodal" => true},
            %{"name" => "opted-out", "probe_multimodal" => false},
            %{"name" => "absent"}
          ]
        })

      assert_reply ref, :ok, %{}, 1_000

      # The push serializes the config the handler just reloaded, so this pins
      # the outbound `true` as well as the `false` the two defaults produce.
      assert_push "providers_updated", %{providers: providers}, 1_000

      by_name = Map.new(providers, &{&1["name"], &1["probe_multimodal"]})
      assert by_name["opted-in"] == true
      assert by_name["opted-out"] == false
      assert by_name["absent"] == false

      # ... and the writer persists the same values.
      toml = File.read!(local_file)
      assert toml =~ ~s(probe-multimodal = true)
      assert toml =~ ~s(probe-multimodal = false)
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

    test "replies invalid_payload on a bad thinking-effort or probe_multimodal value", %{
      socket: socket
    } do
      ref =
        push(socket, "save_providers", %{
          "providers" => [%{"name" => "acme", "default_thinking_effort" => "turbo"}]
        })

      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # A non-boolean `probe_multimodal` is a typo, not an opt-out: it raises
      # (as the TOML parser does) rather than being coerced to `false` and
      # persisted, so the same rescue answers `invalid_payload`.
      ref =
        push(socket, "save_providers", %{
          "providers" => [%{"name" => "acme", "probe_multimodal" => "yes"}]
        })

      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end

    test "does not broadcast on failure", %{socket: socket} do
      ref = push(socket, "save_providers", %{"providers" => %{}})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # The handler has already returned its error reply (`assert_reply`
      # above), and a channel broadcasts before it replies — so a broadcast
      # would already be in this mailbox. No wait is needed. The `0` fence is
      # sound only while `providers_updated` has a single emitter
      # (`Providers.save/2`): a second one could land between the reply and
      # this line.
      refute_push "providers_updated", _, 0
    end

    test "replies invalid_payload for a model with a blank name", %{
      socket: socket,
      local_file: local_file
    } do
      # A blank name is the GUI's own default (`emptyModel()` returns
      # `name: ""`), and the reader rejects it: `ModelValidation.validate_name/2`
      # raises, `DotConfig.load/0` is on `Models.init/1`'s boot path, and the
      # supervisor exhausts into an application shutdown. So a name the app
      # wrote itself could render the app unbootable. The write path has to
      # refuse it, which the same `rescue` turns into `invalid_payload`.
      ref =
        push(socket, "save_providers", %{
          "providers" => [
            %{
              "name" => "acme",
              "auto_models" => false,
              "models" => [%{"name" => "", "context_limit" => 1000}]
            }
          ]
        })

      assert_reply ref, :error, %{"reason" => "invalid_payload"}

      # ... and nothing was written, so the config the app would reload is
      # still the one it started with. This is the property that matters: a
      # refused save must not leave a config behind that the reader rejects.
      refute File.exists?(local_file)
    end

    test "replies invalid_payload for a model whose name is absent", %{
      socket: socket,
      local_file: local_file
    } do
      # A *missing* name is refused by the same guard, so it reports the same
      # way. Before the guard it was caught one layer down by the TOML encoder
      # ("nil is not supported in TOML") and came back as `failed_to_save` —
      # also safe, but for a reason unrelated to the name, and only after
      # `Writer.save_providers/1` had already run.
      ref =
        push(socket, "save_providers", %{
          "providers" => [
            %{
              "name" => "acme",
              "auto_models" => false,
              "models" => [%{"name" => nil, "context_limit" => 1000}]
            }
          ]
        })

      assert_reply ref, :error, %{"reason" => "invalid_payload"}
      refute File.exists?(local_file)
    end

    test "saves a model with a usable name", %{socket: socket, local_file: local_file} do
      # The premise of the two tests above: a well-named model still saves, so
      # the refusals are about the name and not about models in general.
      Mimic.expect(Nest.Models, :rescan, fn -> :ok end)

      ref =
        push(socket, "save_providers", %{
          "providers" => [
            %{
              "name" => "acme",
              "auto_models" => false,
              "models" => [%{"name" => "gpt-x", "context_limit" => 1000}]
            }
          ]
        })

      # An explicit bound, matching this file's other `:ok` assertions (the
      # `:error` ones keep the default because those handlers do no work).
      # `save_providers` writes `local.toml`, parses it back through
      # `DotConfig.load/0` and re-serializes before it replies — the file's own
      # comment on the sibling test calls it the slowest `handle_in` here.
      #
      # The bound is also not the whole story: the lobby channel subscribes to
      # the global `"models"` topic, so a *concurrent* test's `rescan/0` can
      # push `models_updated` into this mailbox at any moment. `assert_reply`
      # matches past those, but it has to be given room to.
      assert_reply ref, :ok, %{}, 1_000
      assert File.read!(local_file) =~ ~s(name = "gpt-x")
    end
  end
end
