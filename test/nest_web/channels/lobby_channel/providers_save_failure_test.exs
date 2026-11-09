defmodule NestWeb.LobbyChannel.ProvidersSaveFailureTest do
  @moduledoc """
  What `save_providers` replies when the **write** fails.

  Split out of `lobby_channel/providers_test.exs`, which is at its file-length
  cap. `Nest.DotConfig.Writer` stops rather than guessing when it cannot use the
  files that tell it which providers a deletion has to be recorded against, and
  it names the file and the reason. This pins that the sentence reaches the
  operator: `failed_to_save` alone does not say whether the payload or the config
  on disk was the problem, and the GUI renders `message` in preference to the
  code.

  Neither case installs a stub mid-test. `Mimic.stub/3` is a sharded
  `GenServer.call`, and under the full suite's contention one inside a test's
  deadline is a stall this file has already been bitten by: the second half used
  to re-point `local_file` at a path that could not be created, and it timed out
  under CPU burners. Making the directory unwritable needs no stub at all, and is
  what `writer_test.exs` does for the same failure.

  Runs `async: true`. The `"lobby"` PubSub topic is process-global, so another
  test's save can land in this mailbox; this file asserts on the failed write and
  its error reply, never on a `providers_updated` frame.
  """

  use NestWeb.ChannelCase, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Repo

  @marker "providers_fail_"

  setup do
    dir = Path.join(System.tmp_dir!(), "#{@marker}#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    local_file = Path.join(dir, "local.toml")

    Mimic.stub(Nest.DotConfig, :local_file, fn -> local_file end)

    on_exit(fn ->
      # The test below makes the directory unwritable, so cleanup has to be able
      # to open it again.
      File.chmod(dir, 0o700)
      rm_tmp!(dir, @marker)
    end)

    {:ok, local_file: local_file, dir: dir}
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
    local_file: local_file,
    dir: dir
  } do
    # A `local.toml` the writer cannot use is a set of deletions it cannot know,
    # so it stops and says which file it could not use. Nothing is written.
    File.write!(local_file, "= not toml\n")

    ref = push(socket, "save_providers", %{"providers" => [%{"name" => "acme-unwritable"}]})

    assert_reply ref, :error, %{"reason" => "failed_to_save", "message" => message}, 1_000
    # The sentence names the file it could not use, which is what makes it
    # actionable — the operator has two files and one of them is broken.
    assert message =~ "cannot use #{local_file}"
    assert File.read!(local_file) == "= not toml\n"

    # A write that cannot land names the file and the filesystem's reason. The
    # record has to get past the parse first, so the file is repaired and then
    # the directory it lives in is made unwritable.
    File.write!(local_file, "")
    File.chmod!(dir, 0o500)

    ref = push(socket, "save_providers", %{"providers" => [%{"name" => "acme-unwritable"}]})

    assert_reply ref, :error, %{"reason" => "failed_to_save", "message" => message}, 1_000
    assert message =~ "could not write #{local_file}"
  end
end
