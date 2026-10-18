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

  alias Nest.Agents.SpaceGate

  setup do
    on_exit(fn -> Application.delete_env(:nest, :space_gate_ttl_ms) end)
    :ok
  end

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

    holder = spawn(fn -> SpaceGate.hold(id) end)
    # `hold` is a call, so the claim exists by the time the process exits.
    assert_receive {:space_unlocked, ^id}, 500
    refute SpaceGate.held?(id)
    refute Process.alive?(holder) and SpaceGate.held?(id)
  end

  test "an abandoned claim expires" do
    Application.put_env(:nest, :space_gate_ttl_ms, 20)
    id = watch(space_id())

    # Held by this process, which never releases it: a client alive but silent.
    assert :ok = SpaceGate.hold(id)
    assert SpaceGate.held?(id)

    assert_receive {:space_unlocked, ^id}, 1_000
    refute SpaceGate.held?(id)
  end
end
