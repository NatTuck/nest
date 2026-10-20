defmodule Nest.Agents.TmpSweeperTest do
  @moduledoc """
  The sweep's three passes and its guards.

  Every test calls `sweep/3` and `mark/2` directly with an injected root and
  clock, so nothing here waits on the timer (the timer's only job is to call
  them). `async: true`: each test builds its own root parent under the OS temp
  dir and names only negative unique space ids, so no test can see another's
  directories or a real agent's registration.
  """
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.TmpSweeper
  alias Nest.Sandbox.{Mounts, ShellJobs}
  alias Nest.Tools.ShellCmd

  @ttl 60 * 60 * 1000

  # `<tmp>/nest-sweeper-<n>/4242`: a private `/tmp/nest` parent with one process
  # root in it. The root's name is all digits, so it looks exactly like a real
  # one — which is what lets the "never our own root" test fail if the guard
  # goes.
  defp root_fixture do
    base = Path.join(System.tmp_dir!(), "nest-sweeper-#{System.unique_integer([:positive])}")
    own = Path.join(base, "4242")
    File.mkdir_p!(own)
    on_exit(fn -> rm_tmp!(base, "nest-sweeper-") end)
    own
  end

  defp peer_root(parent, name, at) do
    root = Path.join(parent, name)
    File.mkdir_p!(root)
    :ok = TmpSpace.write_alive(root, at)
    root
  end

  defp now, do: DateTime.utc_now()

  # A negative id can never collide with a real `spaces.id`, so no test here can
  # be affected by (or affect) a live agent's registration.
  defp unique_negative_space, do: -System.unique_integer([:positive])

  # A live agent registration under `{space_id, name}`, held by a process this
  # test keeps alive until it ends. `Registry.register/3` may only be called by
  # the process being registered, hence the spawn.
  defp register_agent(space_id, name) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Nest.Agents.Registry, {space_id, name}, nil)
        send(test_pid, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  describe "pass 1: peer roots" do
    test "removes a dead peer root, and leaves a fresh one and a root with no .alive" do
      own = root_fixture()
      parent = Path.dirname(own)
      now_ms = System.os_time(:millisecond)

      dead = peer_root(parent, "1111", now_ms - 2 * @ttl)
      fresh = peer_root(parent, "2222", now_ms - 60_000)

      # No `.alive`: not a process root, so not ours to judge.
      unmarked = Path.join(parent, "3333")
      File.mkdir_p!(Path.join(unmarked, "space-1"))

      # An `.alive` that is not a timestamp is a corpse whatever its age: a live
      # sweeper always writes a parseable one.
      garbage = peer_root(parent, "4444", now_ms)
      File.write!(TmpSpace.alive_path(garbage), "not a timestamp")

      # All digits is half the test. A named child is not a process root, however
      # stale it looks — this is what keeps a `"none"` space's suggested
      # `/tmp/nest/<space-name>` directory out of the sweep.
      named = peer_root(parent, "peer-root", now_ms - 2 * @ttl)

      assert :ok = TmpSweeper.sweep(own, now_ms, @ttl)

      refute File.exists?(dead)
      refute File.exists?(garbage)
      assert File.dir?(fresh)
      assert File.dir?(unmarked)
      assert File.dir?(named)
    end

    test "never removes our own root, even when its .alive looks stale" do
      own = root_fixture()
      TmpSpace.write_alive(own, DateTime.add(now(), -10 * @ttl, :millisecond))

      assert :ok = TmpSweeper.sweep(own, now(), @ttl)

      assert File.dir?(own)
      assert File.exists?(TmpSpace.alive_path(own))
    end

    test "the TTL boundary is strict: exactly as old as the TTL stays" do
      own = root_fixture()
      parent = Path.dirname(own)
      now_ms = System.os_time(:millisecond)

      # `>` and not `>=`: a peer that marked one tick ago is alive, so the edge
      # must be kept and only what is strictly older removed.
      edge = peer_root(parent, "5555", now_ms - @ttl)
      older = peer_root(parent, "6666", now_ms - @ttl - 1)

      assert :ok = TmpSweeper.sweep(own, now_ms, @ttl)

      assert File.dir?(edge)
      refute File.exists?(older)
    end

    test "keeps a peer root whose .alive cannot be read" do
      own = root_fixture()
      parent = Path.dirname(own)
      now_ms = System.os_time(:millisecond)

      # The one branch that decides *not* to delete on an error: a marker we
      # cannot read is not evidence that its owner is dead.
      root = peer_root(parent, "7777", now_ms - 2 * @ttl)
      File.chmod!(TmpSpace.alive_path(root), 0o000)

      assert :ok = TmpSweeper.sweep(own, now_ms, @ttl)

      assert File.dir?(root)
    end
  end

  describe "the tick" do
    test "marks, sweeps and reschedules, and ignores a message it does not know" do
      base = Path.join(System.tmp_dir!(), "nest-tick-#{System.unique_integer([:positive])}")
      own = Path.join(base, "4242")
      File.mkdir_p!(own)
      on_exit(fn -> rm_tmp!(base, "nest-tick-") end)

      # Something for the sweep to do, so the tick's effect is observable rather
      # than merely "did not raise": a space with no agent and no job.
      space = Path.join(own, "space-#{unique_negative_space()}")
      File.mkdir_p!(space)

      assert {:ok, state} = TmpSweeper.init(root: own, ttl_ms: @ttl)
      assert %{root: ^own, ttl_ms: @ttl} = state

      # Driven directly rather than by messaging the one registered process: that
      # one sweeps this BEAM's real root, and with it the scratch of every
      # concurrently running async test.
      assert {:noreply, ^state} = TmpSweeper.handle_info(:tick, state)

      # The tick's two effects: it marked the root (the stamp's *form* is
      # `mark/2`'s test, below) and it swept. That the root itself survives is
      # "never removes our own root".
      assert File.exists?(TmpSpace.alive_path(own))
      refute File.exists?(space)

      # The catch-all: a message it does not understand must not crash it.
      assert {:noreply, ^state} = TmpSweeper.handle_info(:not_a_tick, state)
    end
  end

  describe "pass 2: our own agent directories" do
    test "removes an unowned agent directory and keeps .cmds, project and a registered agent" do
      own = root_fixture()
      space_id = unique_negative_space()
      space = Path.join(own, "space-#{space_id}")

      for child <- [".cmds", "project", "orphan", "live"] do
        File.mkdir_p!(Path.join(space, child))
      end

      register_agent(space_id, "live")

      assert :ok = TmpSweeper.sweep(own, now(), @ttl)

      refute File.exists?(Path.join(space, "orphan"))

      # A live owner keeps its directory, and a registered agent in the space
      # keeps the space (and so its children) for pass 3. Each child is also
      # the space surviving — no separate assertion on the parent.
      #
      # `.cmds` and `project` are the two halves of the reject: `".cmds"` fails
      # `Nest.Name.valid?/1`, `"project"` is valid and so needs
      # `@non_agent_children`. Drop either half and that child is rm_rf'd.
      assert File.dir?(Path.join(space, "live"))
      assert File.dir?(Path.join(space, ".cmds"))
      assert File.dir?(Path.join(space, "project"))
    end
  end

  describe "pass 3: our own space directories" do
    test "removes a space directory with no agent and no job, and only that" do
      own = root_fixture()
      space_id = unique_negative_space()
      space = Path.join(own, "space-#{space_id}")
      File.mkdir_p!(Path.join(space, "leftover"))

      # Not `space-<int>`, so not a space directory: never a candidate.
      junk = Path.join(own, "space-not-an-id")
      File.mkdir_p!(junk)

      assert :ok = TmpSweeper.sweep(own, now(), @ttl)

      refute File.exists?(space)
      assert File.dir?(junk)
    end

    test "keeps a space directory while a background job is live in it" do
      own = root_fixture()
      space_id = System.unique_integer([:positive])
      space = Path.join(own, "space-#{space_id}")
      File.mkdir_p!(space)

      key = {space_id, "job-agent"}

      base =
        Path.join(System.tmp_dir!(), "nest-sweeper-job-#{System.unique_integer([:positive])}")

      # Two levels under `/tmp`: `Paths.scratch_root/1` refuses `/tmp` itself as a
      # bind source, and the space directory is what the job's bind is made from.
      scratch = Path.join([base, "space-#{space_id}", "job-agent"])
      File.mkdir_p!(scratch)

      on_exit(fn ->
        ShellJobs.stop_all(key)
        rm_tmp!(base, "nest-sweeper-job-")
      end)

      assert {:ok, _} =
               ShellCmd.execute("sleep 30", Mounts.new(File.cwd!(), scratch), nil,
                 background: true,
                 agent_key: key,
                 grace_ms: 0
               )

      # The barrier: the job is registered in the space, which is what
      # `live_in_space?/1` asks. The wording of `ShellCmd`'s own success message
      # is that module's business, not the sweeper's.
      assert ShellJobs.live_in_space?(space_id)

      assert :ok = TmpSweeper.sweep(own, now(), @ttl)
      assert File.dir?(space)

      assert :ok = ShellJobs.stop_all(key)
      assert :ok = TmpSweeper.sweep(own, now(), @ttl)
      refute File.exists?(space)
    end
  end

  describe "mark/2" do
    test "records the time it is given, in the form the sweep parses back" do
      root = root_fixture()
      at = now()

      assert :ok = TmpSweeper.mark(root, DateTime.add(at, -5_000, :millisecond))

      {:ok, recorded, _offset} =
        root |> TmpSpace.alive_path() |> File.read!() |> DateTime.from_iso8601()

      assert DateTime.diff(at, recorded, :millisecond) == 5_000

      # A Unix time in milliseconds means the same instant.
      assert :ok = TmpSweeper.mark(root, 0)

      {:ok, epoch, _offset} =
        root |> TmpSpace.alive_path() |> File.read!() |> DateTime.from_iso8601()

      assert DateTime.diff(epoch, ~U[1970-01-01 00:00:00Z], :millisecond) == 0
    end
  end
end
