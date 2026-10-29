defmodule NestWeb.LobbyChannel.ProbeCacheTest do
  @moduledoc """
  Tests for the LobbyChannel's `probe_cache_stats` and `clear_probe_cache`
  handlers (`NestWeb.LobbyChannel.ProbeCache`).

  Runs `async: true`. The cache's file is injected by stubbing
  `Nest.LLM.MultimodalCache.path/0`, and that stub is made visible to the
  channel process -- where the handler runs -- with `Mimic.allow/3`, the same
  private-mode pattern the other lobby channel tests use. The real
  `MultimodalCache` server performs the writes, so the file these tests
  assert on is the one the cache really produces.
  """
  use NestWeb.ChannelCase, async: true

  import Mimic
  import Nest.Test.TmpCleanup

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.DotConfig.Provider
  alias Nest.LLM.MultimodalCache
  alias Nest.Repo

  setup :verify_on_exit!

  # The identifying fragment of every temp path this file builds; it is part
  # of each path by construction, and `rm_tmp!/2` requires it.
  @marker "nest_probe_cache_channel_test_"

  setup do
    dir = Path.join(System.tmp_dir!(), "#{@marker}#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "probe-cache.json")

    Mimic.stub(MultimodalCache, :path, fn -> path end)

    on_exit(fn -> rm_tmp!(dir, @marker) end)

    {:ok, path: path}
  end

  describe "handle_in" do
    setup do
      Repo.delete_all(InviteSchema)
      Repo.delete_all(UserSchema)

      {:ok, admin, _role} =
        Accounts.create_user(
          %{username: "probe-cache-admin", password: "password123"},
          "first-user"
        )

      socket = join_lobby(admin)

      {:ok, _invite, invite_token} = Accounts.create_invite(admin.id)

      {:ok, bob} =
        Accounts.redeem_invite(invite_token, %{
          username: "probe-cache-bob",
          password: "password456"
        })

      bob_socket = join_lobby(bob)

      # The handlers run in the channel process, so this test's `path/0` stub
      # has to be visible there. Bob is allowed the stub too: a regression
      # that let a non-admin through must not be able to write the cache's
      # real default file from a test.
      Mimic.allow(MultimodalCache, self(), socket.channel_pid)
      Mimic.allow(MultimodalCache, self(), bob_socket.channel_pid)

      {:ok, socket: socket, bob_socket: bob_socket}
    end

    test "probe_cache_stats replies with the stats and pushes nothing", %{
      socket: socket,
      path: path
    } do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)

      ref = push(socket, "probe_cache_stats", %{})
      assert_reply ref, :ok, %{"stats" => stats}, 1_000

      assert stats.entries == 1
      assert stats.path == path

      # A read: every session on the topic is not told about it. The `0` fence
      # is sound only while `probe_cache_stats` has a single emitter
      # (`ProbeCache.clear/0`): a second one could land between the reply and
      # this line.
      refute_push "probe_cache_stats", _, 0
    end

    test "clear_probe_cache empties the cache, and replies and pushes the new stats", %{
      socket: socket,
      path: path
    } do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)
      assert MultimodalCache.get(provider(), "m") == :positive

      ref = push(socket, "clear_probe_cache", %{})

      expected = %{entries: 0, oldest_age_s: nil, path: path}
      assert_reply ref, :ok, %{"stats" => ^expected}, 1_000
      assert_push "probe_cache_stats", %{stats: ^expected}, 1_000
    end

    test "clearing a cache that was never written is the same no-op", %{
      socket: socket,
      path: path
    } do
      refute File.exists?(path)

      ref = push(socket, "clear_probe_cache", %{})

      expected = %{entries: 0, oldest_age_s: nil, path: path}
      assert_reply ref, :ok, %{"stats" => ^expected}, 1_000
      assert File.exists?(path)
    end

    test "a non-admin is refused on both events, and nothing changes", %{
      bob_socket: bob_socket
    } do
      assert :ok = MultimodalCache.put(provider(), "m", :positive)

      for event <- ["probe_cache_stats", "clear_probe_cache"] do
        ref = push(bob_socket, event, %{})
        assert_reply ref, :error, %{"reason" => "forbidden"}, 1_000
      end

      assert MultimodalCache.get(provider(), "m") == :positive

      # `probe_cache_stats` has a single emitter (`ProbeCache.clear/0`), so
      # with the bounded reply above already received this `0` fence decides
      # the absence: a broadcast would have been emitted before the reply.
      refute_push "probe_cache_stats", _, 0
    end
  end

  # Joins the lobby as `user` and drains the `:after_join` pushes, so a
  # test's own assertions start from a mailbox it knows.
  defp join_lobby(user) do
    {:ok, connected} =
      connect(NestWeb.UserSocket, %{"token" => Accounts.AuthToken.sign(user.id)})

    {:ok, _, socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    assert_push "init", _
    assert_push "broken_agents_updated", _

    socket
  end

  defp provider do
    %Provider{
      name: "p",
      base_url: "http://provider.test/v1",
      api_key: "sk-secret-value",
      protocol: "openai",
      first_byte_timeout_seconds: 30,
      probe_multimodal: true
    }
  end
end
