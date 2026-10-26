defmodule Nest.Agents.Agent.TmpSpaceTest do
  @moduledoc """
  Space-scoped scratch-dir tests: one `/tmp` per **space**, not per agent.

  The layout is `/tmp/nest/<BEAM ospid>/space-<space_id>/<agent-name>`, and the
  **space** directory is what `Nest.Sandbox` binds at `/tmp`, so siblings in a
  space can read each other's scratch files. `async: true`: each test uses a
  unique *negative* space id (impossible to collide with a real `spaces.id`) and
  leaves the space dir behind — no agent removes one, and `Nest.Agents.TmpSweeper`
  owns them (the suite removes its own root at exit, `test/test_helper.exs`).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox
  alias Nest.Sandbox.{Mounts, Paths}
  alias Nest.Test.TmpCleanup

  # A `"none"` agent's scratch is the host's own `/tmp/<name>`, so these tests
  # build their stand-ins under the real temp dir with a unique name that passes
  # the name rule. They deliberately do *not* use the literal host names the
  # guard exists for (`nest`, which is the parent of every BEAM's scratch root,
  # and `snap-private-tmp`): the guard cannot tell them apart from a stand-in, and
  # a test that used one would delete the host's own directory if the guard ever
  # regressed.
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The permission bits, without the file-type bits `File.stat!/1` reports
  # alongside them.
  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # A `"none"` scratch is the host's own `/tmp/<name>`, so a test that makes one
  # has to remove it: production leaves them to the agent's `terminate/2`, and a
  # test that never started an agent has no way to reach that.
  defp track_none_scratch(space_id, name) do
    on_exit(fn -> TmpSpace.cleanup(space_id, name, "none") end)
    name
  end

  defp host_tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> TmpCleanup.rm_tmp!(dir, prefix) end)
    dir
  end

  setup do
    # A *negative* id can never collide with a real `spaces.id` (a
    # positive bigint). A positive `System.unique_integer/1` can, after
    # enough suite runs, land on a live space's id — and then an `on_exit`
    # `rm_rf` of this space dir would delete that live dir out from under a
    # concurrently running test (`bwrap: Can't find source path`).
    #
    # We also do NOT remove the space dir at all: nothing in production does
    # (an agent's `terminate/2` removes only its own sub-dir; `TmpSweeper`
    # removes a space dir when no agent is registered in it and no job is live),
    # so the test mirrors that and can never delete a shared parent.
    space_id = -System.unique_integer([:positive])
    space_dir = TmpSpace.space_dir(space_id, "bwrap")
    %{space_id: space_id, space_dir: space_dir}
  end

  describe "the layout" do
    test "a binding backend's space dir is under this BEAM's root" do
      # The last two segments of the bwrap spelling, each with its own function.
      # The first two are `TmpRootTest`'s (`root_parent/0` and `own_root/0`); the
      # `"none"` spelling is `Nest.Sandbox.NoneBackendTest`'s and the `"docker"`
      # one this file's "a docker space's scratch".
      assert TmpSpace.space_dir(7, "bwrap") == Path.join(TmpSpace.own_root(), "space-7")

      assert TmpSpace.agent_dir(7, "agent-a", "bwrap") ==
               Path.join(TmpSpace.space_dir(7, "bwrap"), "agent-a")
    end
  end

  describe "create/3" do
    test "creates a per-agent dir under one shared space dir", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      a = TmpSpace.create(space_id, "agent-a", "bwrap")
      b = TmpSpace.create(space_id, "agent-b", "bwrap")

      # Both agents share one space dir: it is the parent each path names.
      assert a == Path.join(space_dir, "agent-a")
      assert b == Path.join(space_dir, "agent-b")
      assert File.dir?(a)
      assert File.dir?(b)

      # 0755 rather than the launcher's umask: this is the agent's own scratch
      # directory under /tmp, and a world-writable one is the hazard #178 is about
      # (this suite's umask makes a plain `mkdir_p` 0775).
      assert mode(a) == 0o755
      assert mode(space_dir) == 0o755
    end
  end

  describe "cleanup/3" do
    test "removes only the agent's own dir, leaving the space + siblings", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      a = TmpSpace.create(space_id, "agent-a", "bwrap")
      b = TmpSpace.create(space_id, "agent-b", "bwrap")
      File.write!(Path.join(a, "a.txt"), "a")
      File.write!(Path.join(b, "b.txt"), "b")

      assert :ok = TmpSpace.cleanup(space_id, "agent-a", "bwrap")

      refute File.exists?(a)
      # The space dir is a shared parent and is never rmdir'd, so a sibling
      # survives both its directory and its file.
      assert File.dir?(space_dir)
      assert File.read!(Path.join(b, "b.txt")) == "b"
    end

    test "refuses a hostile agent name instead of escaping the space dir", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      log =
        capture_log(fn ->
          # A real agent dir first, so the refusals below are checked
          # against something that exists.
          keeper = TmpSpace.create(space_id, "keeper", "bwrap")
          assert Path.dirname(keeper) == space_dir

          # ".." would pass a *syntactic* `Path.dirname/1` guard and
          # `rm_rf` the whole shared `nest/<ospid>` root (every space,
          # every agent's scratch). `create/3` refuses it outright (the DB
          # boundary rejects such a name, so this only happens if a caller
          # skipped it)...
          assert_raise ArgumentError, fn -> TmpSpace.create(space_id, "..", "bwrap") end

          # ...and `cleanup/3` (which runs from `terminate/2`, so it must
          # never raise) logs the refusal and removes nothing.
          assert :ok = TmpSpace.cleanup(space_id, "..", "bwrap")

          assert File.dir?(keeper)
          assert File.dir?(space_dir)
        end)

      # The refusal is loud: the log line is the only trace of a `terminate/2`
      # that declined to remove a scratch directory.
      assert log =~ "TmpSpace.cleanup: refusing to rm_rf for an unsafe agent name: \"..\""
    end
  end

  describe "prompt_mounts/6" do
    test "names the agent's real scratch, space and backend", %{space_id: space_id} do
      mounts = TmpSpace.prompt_mounts("/ws", space_id, unique("agent-a"), "docker", true, nil)

      # The scratch directory is named even though nothing created it: composing
      # a prompt runs no sandbox, but the mounts it states must be the agent's
      # real ones, so that what the prompt says about its environment is what its
      # tools will do.
      assert Mounts.scratch(mounts) ==
               TmpSpace.agent_dir(space_id, Mounts.scratch(mounts) |> Path.basename(), "docker")

      assert Mounts.workspace(mounts) == "/ws"
      assert Mounts.backend(mounts) == "docker"
      assert Mounts.space_id(mounts) == space_id
    end

    test "names the directory without making it", %{space_id: space_id} do
      # Naming and making are separate on purpose: the two creators are `create/3`
      # (the start path) and `Mounts.ensure_scratch!/1` (staging), and a scratch
      # path that cannot be made has to fail where the agent starts rather than as
      # a raise out of the caller that is merely composing a prompt.
      name = track_none_scratch(space_id, unique("none-a"))
      mounts = TmpSpace.prompt_mounts(nil, space_id, name, "none", true, nil)

      assert Mounts.scratch(mounts) == Path.join("/tmp", name)
      refute File.exists?(Mounts.scratch(mounts))
    end

    test "ensure_scratch!/1 marks what it makes, and never touches what is there", %{
      space_id: space_id
    } do
      # The staging seam is the other creator of a scratch directory: a `"none"`
      # one it made without the marker would be a directory no later `cleanup/3`
      # could ever remove.
      name = track_none_scratch(space_id, unique("none-a"))
      mounts = TmpSpace.prompt_mounts(nil, space_id, name, "none", true, nil)
      scratch = Mounts.scratch(mounts)

      assert :ok = Mounts.ensure_scratch!(mounts)
      assert File.exists?(Path.join(scratch, ".nest-scratch"))

      # Something at the path that is not Nest's is left unmarked: the marker has
      # to keep meaning "Nest made this", or it is a licence to delete.
      foreign = host_tmp_dir("nest-rmtest-ensure")
      foreign_mounts = Mounts.new(nil, foreign, "none", space_id)

      assert :ok = Mounts.ensure_scratch!(foreign_mounts)
      refute File.exists?(Path.join(foreign, ".nest-scratch"))
      assert File.dir?(foreign)
    end

    test "carries no scratch for a name that cannot be a path component", %{space_id: space_id} do
      # Such an agent is refused by its own changeset, and nothing composes a
      # prompt for it — but this must not raise on the way there. The escape and
      # the empty boundary: every unsafe literal takes the same
      # `Nest.Name.valid?/1` branch, so one of each shape is enough.
      for name <- ["..", ""] do
        assert Mounts.scratch(TmpSpace.prompt_mounts(nil, space_id, name, "bwrap", true, nil)) ==
                 nil
      end
    end
  end

  describe "the \"none\" marker" do
    test "create/3 refuses to adopt a directory that is not Nest's", %{space_id: space_id} do
      # `mkdir_p!` is a no-op on an existing directory, so without this check
      # `create/3` would claim exactly the directories the marker exists to
      # protect — and stamp the marker into one, which is what licenses the next
      # `cleanup/3` to delete it. The name that would be the root parent itself
      # (`/tmp/nest`, the parent of every BEAM's scratch root) is the same
      # branch: a directory that exists and carries no marker.
      dir = host_tmp_dir("nest-rmtest-adopt")
      File.write!(Path.join(dir, "host-file"), "not Nest's")

      assert_raise ArgumentError, ~r/it exists and is not Nest's/, fn ->
        TmpSpace.create(space_id, Path.basename(dir), "none")
      end

      refute File.exists?(Path.join(dir, ".nest-scratch"))
      assert File.read!(Path.join(dir, "host-file")) == "not Nest's"
    end

    test "create/3 re-opens a marked directory idempotently", %{space_id: space_id} do
      # Re-creating a stopped agent's scratch is the ordinary path, and it must
      # not look like adoption.
      name = track_none_scratch(space_id, unique("none-a"))
      first = TmpSpace.create(space_id, name, "none")

      assert TmpSpace.create(space_id, name, "none") == first
      assert File.exists?(Path.join(first, ".nest-scratch"))
    end

    test "cleanup/3 removes a marked none scratch", %{space_id: space_id} do
      name = track_none_scratch(space_id, unique("none-a"))
      path = TmpSpace.create(space_id, name, "none")
      assert File.dir?(path)

      assert :ok = TmpSpace.cleanup(space_id, name, "none")
      refute File.exists?(path)
    end

    test "cleanup/3 refuses an unmarked directory", %{space_id: space_id} do
      # The name rule alone cannot tell Nest's directory from the host's: a
      # `"none"` agent named `nest` would name the parent of every BEAM's scratch
      # root, and `snap-private-tmp` is a real `/tmp` entry that passes the same
      # rule. Neither is Nest's without the marker, so the name it carries
      # decides nothing — this one is a plain host directory of the same shape.
      dir = host_tmp_dir("nest-rmtest")
      File.write!(Path.join(dir, "host-file"), "not Nest's")

      # The refusal is an `:error` line — a directory that exists and is not
      # Nest's is worth an operator's attention — so the test that provokes it
      # captures and asserts it rather than letting it into the suite output.
      # Inclusion only: `capture_log` collects every process's lines.
      log =
        capture_log(fn ->
          assert :ok = TmpSpace.cleanup(space_id, Path.basename(dir), "none")
        end)

      assert log =~ "it is not a Nest scratch directory"
      assert File.dir?(dir), "#{dir} was removed without Nest's marker"
      assert File.read!(Path.join(dir, "host-file")) == "not Nest's"
    end

    test "remove_stale/3 obeys the same rule", %{space_id: space_id} do
      name = track_none_scratch(space_id, unique("none-a"))
      marked = TmpSpace.create(space_id, name, "none")
      unmarked = host_tmp_dir("nest-rmtest-stale")

      assert :ok = TmpSpace.remove_stale(space_id, name, "none")
      refute File.exists?(marked)

      log =
        capture_log(fn ->
          assert :ok = TmpSpace.remove_stale(space_id, Path.basename(unmarked), "none")
        end)

      assert log =~ "it is not a Nest scratch directory"
      assert File.dir?(unmarked)
    end

    test "remove_stale/3 ignores a name that cannot be a path component", %{space_id: space_id} do
      # It runs before the row changeset refuses the name, and must not raise.
      assert :ok = TmpSpace.remove_stale(space_id, "..", "none")
    end

    test "a bwrap scratch is removed without a marker", %{space_id: space_id} do
      # Its path already carries `nest/<BEAM pid>/space-<id>`, so there is
      # nothing to disambiguate.
      name = unique("bwrap-a")
      path = TmpSpace.create(space_id, name, "bwrap")
      refute File.exists?(Path.join(path, ".nest-scratch"))

      assert :ok = TmpSpace.cleanup(space_id, name, "bwrap")
      refute File.exists?(path)
    end
  end

  describe "cross-agent scratch sharing" do
    test "the sandbox /tmp is the shared space dir (siblings share it; host /tmp is untouched)",
         %{space_id: space_id, space_dir: space_dir} do
      caps = Sandbox.default_caps()

      # A workspace outside /tmp (the /tmp bind shadows anything under
      # the host /tmp, including the scratch dirs themselves).
      ws =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest_tmp_space_ws_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(ws)
      on_exit(fn -> rm_tmp!(ws, "nest_tmp_space_ws_") end)

      a = TmpSpace.create(space_id, "agent-a", "bwrap")
      b = TmpSpace.create(space_id, "agent-b", "bwrap")

      # Agent A writes into its own scratch dir. This is the shape the
      # `Overflow` writers produce (a direct host write).
      File.write!(Path.join(a, "report.txt"), "shared result\n")

      # B's sandbox sees the same /tmp (the space dir), so A's file is
      # readable at /tmp/agent-a/report.txt.
      assert {:ok, out} =
               Sandbox.run("cat /tmp/agent-a/report.txt", Mounts.new(ws, b), caps)

      assert out =~ "shared result"

      # A write to /tmp lands under the space dir; the host /tmp is
      # shadowed and untouched. (This, not `write_allowed?/3`, is the
      # real enforcement — `write_allowed?/3` has no production caller;
      # the bwrap mount is the gate.)
      leak = "leak-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Sandbox.run("echo x > /tmp/#{leak}", Mounts.new(ws, b), caps)

      assert File.read!(Path.join(space_dir, leak)) == "x\n"
      refute File.exists?(Path.join("/tmp", leak))
    end
  end

  describe "a docker space's scratch" do
    test "is a path inside the container, and nothing on the host is created for it" do
      name = unique("docker-agent")

      # The container's own `/tmp` is the scratch root, so the agent's directory
      # is the bare name under the `/tmp` spelling — the same spelling every
      # agent is told it has, on every backend.
      assert TmpSpace.space_dir(7, "docker") == Paths.sandbox_root()

      # `create/3` only *names* it (the same path `agent_dir/3` derives): the
      # container makes it, in the command that runs. Making it here would leave
      # a host directory at a spelling the container would never see.
      assert TmpSpace.create(7, name, "docker") == Path.join("/tmp", name)
      refute File.exists?(Path.join("/tmp", name))
    end

    test "has nothing to remove, and removes nothing that shares its name" do
      name = unique("docker-agent")
      host_dir = Path.join("/tmp", name)
      File.mkdir_p!(host_dir)
      on_exit(fn -> rm_tmp!(host_dir, "docker-agent-") end)

      # A host directory that happens to have the agent's name is not this
      # space's to delete: the scratch it stands for is in the container.
      assert :ok = TmpSpace.cleanup(7, name, "docker")
      assert :ok = TmpSpace.remove_stale(7, name, "docker")
      assert File.dir?(host_dir)
    end
  end
end
