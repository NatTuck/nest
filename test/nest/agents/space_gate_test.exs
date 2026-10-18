defmodule Nest.Agents.SpaceGateTest do
  @moduledoc """
  The per-space before-starts latch: who may hold it, who may release it, how a
  waiter is woken, and the two ways a claim can end without its owner's word (the
  owner dying, and the TTL).

  Every test uses its own space id, so the singleton server is shared without the
  tests colliding — and the release is asserted from the *broadcast* rather than
  by polling, which is also what proves the wake-up path a blocked tool worker
  depends on.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.SpaceGate

  defp space_id, do: System.unique_integer([:positive])

  # Subscribe before holding, so the release frame cannot be missed — the same
  # ordering rule `await/2` itself uses.
  defp watch(id) do
    Phoenix.PubSub.subscribe(Nest.PubSub, SpaceGate.topic(id))
    id
  end

  test "hold marks the space, release clears it, and the release is broadcast" do
    id = watch(space_id())

    refute SpaceGate.held?(id)
    assert :ok = SpaceGate.hold(id)
    assert SpaceGate.held?(id)

    assert :ok = SpaceGate.release(id)
    refute SpaceGate.held?(id)
    assert_receive {:space_unlocked, ^id}, 500
  end

  test "a second session is refused, and the holder can ask again" do
    id = watch(space_id())
    assert :ok = SpaceGate.hold(id)

    # A different process is another session: two edits of one space at once is
    # exactly what the latch is for.
    assert {:error, :already_held} = Task.async(fn -> SpaceGate.hold(id) end) |> Task.await()

    # The same process asking twice is the two-push edit — preview, then confirm.
    assert :ok = SpaceGate.hold(id)
    assert SpaceGate.held?(id)
  end

  test "only the holder may release" do
    id = watch(space_id())
    assert :ok = SpaceGate.hold(id)

    assert :ok = Task.async(fn -> SpaceGate.release(id) end) |> Task.await()

    assert SpaceGate.held?(id)
    refute_receive {:space_unlocked, ^id}, 50

    assert :ok = SpaceGate.release(id)
    assert_receive {:space_unlocked, ^id}, 500
  end

  test "a waiter blocks until the release, then proceeds" do
    id = watch(space_id())
    assert :ok = SpaceGate.hold(id)

    waiter = Task.async(fn -> SpaceGate.await(id) end)

    # It has not returned while the space is held.
    assert Task.yield(waiter, 30) == nil

    assert :ok = SpaceGate.release(id)
    assert :ok = Task.await(waiter, 500)
  end

  test "a waiter on an unheld space does not block" do
    assert :ok = SpaceGate.await(space_id(), 0)
  end

  test "a context with no space behind it is never gated" do
    # `BatchSizer`'s unit tests build a ctx without a space; there is no
    # environment for the latch to protect and no id it could be held under.
    assert :ok = SpaceGate.await(nil, 0)
    assert :ok = SpaceGate.await("not a space", 0)
  end

  test "the holder dying releases the space" do
    id = watch(space_id())

    spawn(fn -> SpaceGate.hold(id) end)
    # `hold` is a call, so the claim exists by the time the process exits, and the
    # release frame is the owner's `:DOWN` arriving.
    assert_receive {:space_unlocked, ^id}, 500
    refute SpaceGate.held?(id)
  end

  test "a second hold from the same owner re-arms the TTL" do
    id = watch(space_id())

    # The two-push edit: a preview, then the confirmation that has to cover its
    # own quiesce and write. The confirmation's window is what counts, so the
    # claim must not keep running on the preview's clock.
    assert :ok = SpaceGate.hold(id, :space_edit, 30)
    assert :ok = SpaceGate.hold(id, :space_edit, 500)

    # Nothing releases the space across the first TTL's expiry point. (A late
    # timer can only make this pass, so load cannot turn it into a failure.)
    refute_receive {:space_unlocked, ^id}, 200
    assert SpaceGate.held?(id)
  end

  test "an abandoned claim expires" do
    id = watch(space_id())

    # Held by this process, which never releases it: a client alive but silent.
    # The TTL is passed per hold — a process-global setting would shorten every
    # other test's claim too.
    log =
      capture_log(fn ->
        assert :ok = SpaceGate.hold(id, :space_edit, 20)
        assert SpaceGate.held?(id)

        assert_receive {:space_unlocked, ^id}, 1_000
        refute SpaceGate.held?(id)
      end)

    # The expiry is the only record of *why* a paused space resumed by itself, and
    # the reason is what names the edit it was.
    assert log =~ "the space_edit claim expired after 20ms"
    assert log =~ "the space resumed without it"
  end
end
