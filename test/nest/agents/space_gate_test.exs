defmodule Nest.Agents.SpaceGateTest do
  @moduledoc """
  The per-space before-starts latch: who may hold it, who may release it, how a
  waiter is woken, and the two ways a claim can end without its owner's word (the
  owner dying, and the TTL).

  Every test uses its own space id, so the singleton server is shared without the
  tests colliding — and the release is asserted from the *broadcast* rather than
  by polling, which is also what proves the wake-up path a blocked tool worker
  depends on.

  The latch's refusal of a second session, and the callers that block in
  `await/2`, are covered end-to-end by `Nest.Spaces.EnvironmentConfirmTest` and
  `Nest.Agents.Agent.BatchSizerTest`, so they are not repeated here.
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

  test "only the holder may release" do
    id = watch(space_id())
    assert :ok = SpaceGate.hold(id)

    # A release from another process is another session: it must leave the claim
    # up, and the owner's monitor and TTL with it.
    assert :ok = Task.async(fn -> SpaceGate.release(id) end) |> Task.await()
    assert SpaceGate.held?(id)

    assert :ok = SpaceGate.release(id)
    assert_receive {:space_unlocked, ^id}, 500
  end

  test "a waiter past its ceiling proceeds without the latch, and says so" do
    id = watch(space_id())
    assert :ok = SpaceGate.hold(id)

    log = capture_log(fn -> assert :ok = SpaceGate.await(id, 20) end)

    # It gave up rather than hanging the tool worker, and said so without
    # diagnosing a cause it cannot know.
    assert log =~ "stayed held past the wait ceiling"
    assert SpaceGate.held?(id)
    assert :ok = SpaceGate.release(id)
  end

  test "the holder dying releases the space" do
    id = watch(space_id())

    spawn(fn -> SpaceGate.hold(id) end)
    # `hold` is a call, so the claim exists by the time the process exits, and the
    # release frame is the owner's `:DOWN` arriving.
    assert_receive {:space_unlocked, ^id}, 500
  end

  test "a second hold from the same owner re-arms the TTL" do
    id = watch(space_id())

    # The two-push edit: a preview, then the confirmation that has to cover its
    # own quiesce and write. The confirmation's window is what counts, so the
    # claim must not keep running on the preview's clock.
    assert :ok = SpaceGate.hold(id, :space_edit, 30)
    assert :ok = SpaceGate.hold(id, :space_edit, 500)

    # Nothing releases the space across the first TTL's expiry point. The
    # interval is the discriminating one: the first hold's TTL was 30 ms, so
    # 50 ms is past it — a `refute_receive` pays its whole window, so this is
    # the smallest window that still crosses the point being tested. (A late
    # timer can only make this pass, so load cannot turn it into a failure.)
    refute_receive {:space_unlocked, ^id}, 50
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
      end)

    # The expiry is the only record of *why* a paused space resumed by itself, and
    # the reason is what names the edit it was.
    assert log =~ "the space_edit claim expired after 20ms"
    assert log =~ "the space resumed without it"
  end
end
