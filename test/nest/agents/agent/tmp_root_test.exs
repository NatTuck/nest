defmodule Nest.Agents.Agent.TmpRootTest do
  @moduledoc """
  The per-BEAM scratch *root* (`TmpSpace.own_root/0`) and its `.alive` mark.

  `async: false`, deliberately and for one concrete reason: these tests remove
  the root every concurrently running agent's scratch directory lives under. A
  `rm_rf` of it during another test's `shell-cmd` deletes that agent's tmp dir
  under a starting `bwrap`, which fails with `bwrap: Can't find source path` —
  the documented flake (`test/nest/agents/agent_tmp_path_test.exs`). ExUnit runs
  sync modules after every async one, so nothing else is live here.
  """
  use ExUnit.Case, async: false

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.TmpSpace

  setup do
    # Leave the suite's root marked alive again: a test here may remove it, and
    # the rest of the suite keeps making space directories under it.
    on_exit(fn -> TmpSpace.prepare_own_root() end)
    :ok
  end

  test "root_parent/0, own_root/0 and alive_path/1 name this BEAM's root" do
    assert TmpSpace.root_parent() == "/tmp/nest"
    assert TmpSpace.own_root() == Path.join("/tmp/nest", System.pid())
    assert TmpSpace.alive_path(TmpSpace.own_root()) == TmpSpace.own_root() <> "/.alive"
  end

  test "prepare_own_root/0 clears a recycled pid's root and marks the new one" do
    root = TmpSpace.own_root()
    # A corpse: something a previous BEAM with this pid left behind, `.alive`
    # and all. We are the process with that pid, so it is ours to remove.
    corpse = Path.join(root, "space--#{System.unique_integer([:positive])}")
    File.mkdir_p!(corpse)
    File.write!(TmpSpace.alive_path(root), "2020-01-01T00:00:00Z")

    TmpSpace.prepare_own_root()

    refute File.exists?(corpse)

    # The mark is fresh, and in the form the sweeper parses back. Reading it also
    # proves the root exists, so there is no separate assertion on the directory.
    {:ok, at, _offset} = root |> TmpSpace.alive_path() |> File.read!() |> DateTime.from_iso8601()
    assert DateTime.diff(DateTime.utc_now(), at, :second) < 60
  end

  test "prepare_root/2 retries when the root is removed between the create and the write" do
    base = Path.join(System.tmp_dir!(), "nest-root-test-#{System.unique_integer([:positive])}")
    root = Path.join(base, "4242")
    on_exit(fn -> rm_tmp!(base, "nest-root-test-") end)

    attempts = :counters.new(1, [])

    # The window the retry exists for: a peer's sweeper removes the directory
    # after we made it and before we wrote `.alive` (it has no way to know we
    # are between two calls). One attempt loses; the next one has to recover.
    interleave = fn ->
      if :counters.get(attempts, 1) == 0 do
        :counters.add(attempts, 1, 1)
        File.rm_rf!(root)
      end
    end

    TmpSpace.prepare_root(root, interleave)

    assert :counters.get(attempts, 1) == 1
    # The write landed inside the directory, which also proves the directory
    # survived the peer's `rm_rf` and was remade.
    assert File.exists?(TmpSpace.alive_path(root))
  end

  test "remove_own_root/0 removes this BEAM's root" do
    TmpSpace.prepare_own_root()
    # Not redundant with the assertion below: without a root to remove, the
    # `refute` would pass for a `remove_own_root/0` that did nothing.
    assert File.dir?(TmpSpace.own_root())

    TmpSpace.remove_own_root()
    refute File.exists?(TmpSpace.own_root())
  end
end
