defmodule NestWeb.LobbyChannelRescanModelsTest do
  @moduledoc """
  Regression tests for the `rescan_models` push completion contract.

  INTENDED BEHAVIOR — DO NOT WEAKEN WITHOUT AN EXPLICIT USER
  INSTRUCTION:

  A `rescan_models` push must NOT be answered until the scan it
  started is genuinely finished. `Nest.Models` streams a
  `{:models_updated, _}` per provider as a *partial* and only then
  emits a single terminal `{:models_scan_complete, %{scan_id: id}}`.
  The channel defers the push reply until it sees that terminal event
  for the same scan id. Answering the push immediately (the old
  fire-and-forget behavior) or on the first partial (the old
  "models changed = done" client heuristic) is the bug this file
  locks out: a fast first provider would re-enable the button
  mid-scan and the rescan looked like a no-op.
  """
  use NestWeb.ChannelCase, async: false

  import Mimic

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken

  setup :set_mimic_global

  # `async: false` is required, and for two independent reasons:
  #
  #   1. `set_mimic_global/0` above. The stub is for `Nest.Models.rescan/0`,
  #      which runs inside the channel process, so it has to be visible
  #      across processes — that is exactly what global mode means, and
  #      global mode must not overlap another module's Mimic state.
  #   2. `LobbyChannel.join/3` subscribes every lobby client to the global
  #      `"models"` topic (`lobby_channel.ex:89`). The broadcasts below are
  #      therefore visible to every concurrently-joined lobby socket in the
  #      suite, so running this file in the async phase would inject
  #      `models_updated` / `models_scan_complete` into unrelated tests.
  setup do
    unique = System.unique_integer([:positive])

    {:ok, user, _role} =
      Accounts.create_user(
        %{username: "rescan-#{unique}", password: "password123"},
        "rescan-token-#{unique}"
      )

    {:ok, %{auth_token: AuthToken.sign(user.id)}}
  end

  describe "rescan_models completion contract" do
    test "the push is answered only by its own scan's completion event", %{
      auth_token: auth_token
    } do
      socket = join_lobby(auth_token)

      stub(Nest.Models, :rescan, fn -> 4242 end)
      ref = push(socket, "rescan_models", %{})

      # A per-provider partial must never produce the reply. `refute_no_reply/2`
      # synchronises the channel process, so this is a deterministic check on
      # the reply the channel *would* have sent — not a timing window.
      broadcast_models_updated()
      refute_no_reply(socket, ref)

      # Neither may a completion for a different scan.
      broadcast_scan_complete(999_999)
      refute_no_reply(socket, ref)

      # Only the matching scan's terminal event does.
      broadcast_scan_complete(4242)
      assert_reply ref, :ok, %{"scan_id" => 4242}
    end

    test "every push waiting on the same scan is answered", %{auth_token: auth_token} do
      socket = join_lobby(auth_token)

      stub(Nest.Models, :rescan, fn -> 7 end)

      ref_a = push(socket, "rescan_models", %{})
      ref_b = push(socket, "rescan_models", %{})

      broadcast_scan_complete(7)

      assert_reply ref_a, :ok, %{"scan_id" => 7}
      assert_reply ref_b, :ok, %{"scan_id" => 7}
    end
  end

  defp join_lobby(auth_token) do
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => auth_token})
    {:ok, _reply, socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    assert_push "init", _payload
    # The `:after_join` broken-agents fetch runs in a spawned task; wait
    # for its push so it can't outlive the test's sandbox checkout.
    assert_push "broken_agents_updated", %{broken_agents: _list}, 1_000

    socket
  end

  # Assert that `ref` has produced no reply at all.
  #
  # The previous form was `refute_reply ref, :ok, 200`, which is the
  # three-argument `refute_reply(ref, status, payload)` — so it refuted a
  # reply whose payload was the integer `200`, a shape this channel can
  # never produce, while spending the 100 ms default timeout doing it.
  # The assertion was vacuous and cost ~200 ms per run of this file.
  #
  # `:sys.get_state/1` is a synchronous call to the channel process: when it
  # returns, every `"models"` broadcast sent above has already been handled
  # (Phoenix.PubSub delivers to subscriber mailboxes before `broadcast/3`
  # returns), so any reply the channel was going to send is already in the
  # test mailbox. `refute_receive ..., 0` then checks it with no wait.
  defp refute_no_reply(socket, ref) do
    _ = :sys.get_state(socket.channel_pid)
    refute_receive %Phoenix.Socket.Reply{ref: ^ref}, 0
  end

  defp broadcast_models_updated do
    Phoenix.PubSub.broadcast(Nest.PubSub, "models", {:models_updated, []})
  end

  defp broadcast_scan_complete(scan_id) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "models",
      {:models_scan_complete, %{scan_id: scan_id, models: []}}
    )
  end
end
