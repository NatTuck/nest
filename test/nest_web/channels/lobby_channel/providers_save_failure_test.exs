defmodule NestWeb.LobbyChannel.ProvidersSaveFailureTest do
  @moduledoc """
  What `save_providers` replies when the **write** fails.

  Split out of `lobby_channel/providers_test.exs`, which is at its file-length
  cap. `Nest.DotConfig.Writer` stops rather than guessing when it cannot read the
  files that tell it which providers a deletion has to be recorded against, and
  it names the file and the reason. This pins that the sentence reaches the
  operator: `failed_to_save` alone does not say whether the payload or the config
  on disk was the problem, and the GUI renders `message` in preference to the
  code.
  """

  use NestWeb.ChannelCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Repo

  setup do
    local_file =
      Path.join(System.tmp_dir!(), "providers_fail_#{System.unique_integer([:positive])}.toml")

    Mimic.stub(Nest.DotConfig, :local_file, fn -> local_file end)
    on_exit(fn -> File.rm(local_file) end)

    {:ok, local_file: local_file}
  end

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "providers-fail-admin", password: "password123"},
        "first-user"
      )

    token = Accounts.AuthToken.sign(user.id)

    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    # Drain the `:after_join` init + broken-agents pushes so the assertions
    # below start from a clean mailbox.
    assert_push "init", _
    assert_push "broken_agents_updated", _

    # The handler runs in the channel process; make this test's `local_file`
    # stub visible there.
    Mimic.allow(Nest.DotConfig, self(), socket.channel_pid)

    {:ok, socket: socket}
  end

  test "replies failed_to_save with the reason the writer stopped", %{
    socket: socket,
    local_file: local_file
  } do
    # A `local.toml` the writer cannot read is a set of deletions it cannot
    # know, so it stops and says which file it could not read. Nothing is
    # written.
    File.write!(local_file, "= not toml\n")

    ref = push(socket, "save_providers", %{"providers" => [%{"name" => "acme"}]})

    assert_reply ref, :error, %{"reason" => "failed_to_save", "message" => message}, 1_000
    assert message =~ "cannot read"
    assert File.read!(local_file) == "= not toml\n"

    # A write that cannot land names the file and the filesystem's reason. A
    # regular file where the parent directory has to be is the cheapest way to
    # make `mkdir_p/1` fail without touching anything shared.
    blocker = local_file <> ".blocker"
    File.write!(blocker, "")
    on_exit(fn -> File.rm(blocker) end)
    Mimic.stub(Nest.DotConfig, :local_file, fn -> Path.join(blocker, "local.toml") end)

    ref = push(socket, "save_providers", %{"providers" => [%{"name" => "acme"}]})

    assert_reply ref, :error, %{"reason" => "failed_to_save", "message" => message}, 1_000
    assert message =~ "could not write"
  end
end
