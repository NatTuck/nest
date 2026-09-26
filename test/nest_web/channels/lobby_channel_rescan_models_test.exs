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

      # A per-provider partial must never produce the reply.
      broadcast_models_updated()
      refute_reply ref, :ok, 200

      # Neither may a completion for a different scan.
      broadcast_scan_complete(999_999)
      refute_reply ref, :ok, 200

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
