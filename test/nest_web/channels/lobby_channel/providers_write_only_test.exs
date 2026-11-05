defmodule NestWeb.LobbyChannel.ProvidersWriteOnlyTest do
  @moduledoc """
  The provider api key is write-only (#202): the payload says `has_api_key` and
  never the value, and a save carries the key in three explicit states.

  Why the value is never sent is in `NestWeb.LobbyChannel.Providers`; this pins
  it. Split out of `lobby_channel/providers_test.exs`, which is at its
  file-length cap.

  The base defines a literal key and a provider with none; the overlay defines a
  `file:` reference, so the three shapes are one payload away from each other.
  """

  use NestWeb.ChannelCase, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.DotConfig
  alias Nest.Repo
  alias NestWeb.LobbyChannel.Providers

  @marker "providers_wo_"

  setup do
    dir = Path.join(System.tmp_dir!(), "#{@marker}#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    base = Path.join(dir, "config.toml")
    local_file = Path.join(dir, "local.toml")
    key_file = Path.join(dir, "key.txt")
    File.write!(key_file, "resolved-from-file\n")

    File.write!(base, """
    [providers.with-key]
    base-url = "https://with-key.example/v1"
    api-key = "base-secret"

    [providers.no-key]
    base-url = "https://no-key.example/v1"
    """)

    # The reference lives in the overlay, where the app's own editor writes.
    File.write!(local_file, """
    [providers.referenced]
    base-url = "https://referenced.example/v1"
    api-key = "file:#{key_file}"
    """)

    Mimic.stub(DotConfig, :local_file, fn -> local_file end)
    Mimic.stub(DotConfig, :config_file, fn -> base end)

    on_exit(fn -> rm_tmp!(dir, @marker) end)

    {:ok, local_file: local_file, key_file: key_file}
  end

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, admin, _role} =
      Accounts.create_user(
        %{username: "write-only-admin", password: "password123"},
        "first-user"
      )

    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Accounts.AuthToken.sign(admin.id)})

    {:ok, _, socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    assert_push "init", init
    assert_push "broken_agents_updated", _

    Mimic.allow(DotConfig, self(), socket.channel_pid)

    {:ok, socket: socket, init: init}
  end

  test "the payload says whether a key is configured, and never what it is", %{init: init} do
    by_name = Map.new(init.providers, &{&1["name"], &1})

    # A literal key in the base, a `file:` reference in the overlay, and a
    # provider with none: a reference counts as configured, because the provider
    # does have a key — it is just resolved elsewhere.
    assert by_name["with-key"]["has_api_key"] == true
    assert by_name["referenced"]["has_api_key"] == true
    assert by_name["no-key"]["has_api_key"] == false

    # The absence is the point: `init` goes to every authenticated user, so a
    # value here would be readable by any of them — and a reference would name
    # the variable or file the secret comes from.
    for {_name, provider} <- by_name do
      refute Map.has_key?(provider, "api_key")
    end

    refute inspect(init.providers) =~ "base-secret"
    refute inspect(init.providers) =~ "file:"
    refute inspect(init.providers) =~ "resolved-from-file"
  end

  test "a non-admin's payload carries no keys either" do
    {:ok, plain, _role} =
      Accounts.create_user(
        %{username: "write-only-plain", password: "password123"},
        "invite-token"
      )

    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Accounts.AuthToken.sign(plain.id)})

    {:ok, _, _socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")
    assert_push "init", init
    assert_push "broken_agents_updated", _

    # They cannot save (the handler is admin-gated), but they can *join* — which
    # is exactly why the value cannot be in this payload.
    assert Enum.all?(init.providers, &(not Map.has_key?(&1, "api_key")))
    assert Enum.any?(init.providers, &(&1["has_api_key"] == true))
    refute inspect(init.providers) =~ "base-secret"
  end

  test "a save with nothing typed keeps the stored key, reference and all", %{
    socket: socket,
    local_file: local_file,
    key_file: key_file
  } do
    # The full set the GUI manages, so the save records no deletions either.
    ref =
      push(socket, "save_providers", %{
        "providers" => [
          %{"name" => "referenced"},
          %{"name" => "with-key"},
          %{"name" => "no-key"}
        ]
      })

    assert_reply ref, :ok, %{}, 1_000

    # Verbatim: the reference is what is stored, never the secret it resolves to.
    toml = File.read!(local_file)
    assert toml =~ ~s(api-key = "file:#{key_file}")
    refute toml =~ "resolved-from-file"

    assert {:ok, config} = DotConfig.load()
    assert config.providers["referenced"].api_key == "file:#{key_file}"
    # The overlay holds no key for `with-key`, so the base's still applies: an
    # omitted line is a keep, not an empty one.
    assert config.providers["with-key"].api_key == "base-secret"
  end

  test "a typed key replaces the stored one", %{socket: socket, local_file: local_file} do
    ref =
      push(socket, "save_providers", %{
        "providers" => [%{"name" => "with-key", "api_key" => "typed-secret"}]
      })

    assert_reply ref, :ok, %{}, 1_000
    assert File.read!(local_file) =~ ~s(api-key = "typed-secret")

    assert {:ok, config} = DotConfig.load()
    assert config.providers["with-key"].api_key == "typed-secret"
  end

  test "clearing writes an empty key, which shadows the base's", %{
    socket: socket,
    local_file: local_file
  } do
    ref =
      push(socket, "save_providers", %{
        "providers" => [%{"name" => "with-key", "clear_api_key" => true}]
      })

    assert_reply ref, :ok, %{}, 1_000
    assert File.read!(local_file) =~ ~s(api-key = "")

    # Empty, not absent: the overlay's own line is what stops the base's key
    # from applying, so the provider really has no key after the clear.
    assert {:ok, config} = DotConfig.load()
    assert config.providers["with-key"].api_key == ""

    removed = Enum.find(Providers.providers(), &(&1["name"] == "with-key"))
    assert removed["has_api_key"] == false
  end

  test "a new provider with no key writes no api-key line", %{
    socket: socket,
    local_file: local_file
  } do
    ref = push(socket, "save_providers", %{"providers" => [%{"name" => "brand-new"}]})

    assert_reply ref, :ok, %{}, 1_000

    toml = File.read!(local_file)
    assert toml =~ "brand-new"
    refute toml =~ "api-key"
  end

  test "refuses an ambiguous key state instead of guessing", %{
    socket: socket,
    local_file: local_file
  } do
    # The three states are explicit on purpose: an empty value is neither "keep"
    # nor "clear", and a payload that both sets and clears has no winner.
    before = File.read!(local_file)

    for {payload, expected} <- [
          {%{"name" => "acme", "api_key" => ""}, ~r/`api_key` is empty/},
          {%{"name" => "acme", "api_key" => "k", "clear_api_key" => true}, ~r/contradict/},
          {%{"name" => "acme", "clear_api_key" => "yes"}, ~r/invalid clear_api_key/}
        ] do
      ref = push(socket, "save_providers", %{"providers" => [payload]})

      assert_reply ref, :error, %{"reason" => "invalid_payload", "message" => message}, 1_000
      assert message =~ expected
      # A refusal writes nothing, so the overlay is byte-for-byte what it was.
      assert File.read!(local_file) == before
    end
  end
end
