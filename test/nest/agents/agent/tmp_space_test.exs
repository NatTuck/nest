defmodule Nest.Agents.Agent.TmpSpaceTest do
  @moduledoc """
  Space-scoped scratch-dir tests: one `/tmp` per **space**, not per agent.

  The layout is `/tmp/nest-<BEAM ospid>/space-<space_id>/<agent-name>`,
  and the **space** directory is what `Nest.Sandbox` binds at `/tmp`, so
  siblings in a space can read each other's scratch files. `async: true`:
  each test uses a unique *negative* space id (impossible to collide with
  a real `spaces.id`) and leaves the space dir to OS `/tmp` cleanup, as
  production does.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Test.TmpCleanup

  # A `"none"` agent's scratch is the host's own `/tmp/<name>`, so these tests
  # build their stand-ins under the real temp dir with a unique name that passes
  # the name rule. They deliberately do *not* use the literal host names the
  # guard exists for (`nest-<pid>`, `X11-unix`, `snap-private-tmp`): the guard
  # cannot tell them apart from a stand-in, and a test that used one would delete
  # the host's own directory if the guard ever regressed.
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

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
    # We also do NOT remove the space dir at all: production never does
    # (an agent's `terminate/2` removes only its own sub-dir, and the
    # space dir is left to OS `/tmp` cleanup), so the test mirrors that
    # and can never delete a shared parent.
    space_id = -System.unique_integer([:positive])
    space_dir = TmpSpace.space_dir(space_id, "bwrap")
    %{space_id: space_id, space_dir: space_dir}
  end

  describe "create/2" do
    test "creates a per-agent dir under one shared space dir", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        a = TmpSpace.create(space_id, "agent-a", "bwrap")
        b = TmpSpace.create(space_id, "agent-b", "bwrap")

        assert a == Path.join(space_dir, "agent-a")
        assert b == Path.join(space_dir, "agent-b")
        assert File.dir?(a)
        assert File.dir?(b)
        # Both agents share one space dir (the parent of each).
        assert Path.dirname(a) == Path.dirname(b)
        assert Path.dirname(a) == space_dir
      end)
    end

    test "is idempotent", %{space_id: space_id} do
      capture_log(fn ->
        first = TmpSpace.create(space_id, "agent-a", "bwrap")
        assert TmpSpace.create(space_id, "agent-a", "bwrap") == first
      end)
    end
  end

  describe "cleanup/2" do
    test "removes only the agent's own dir, leaving the space + siblings", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        a = TmpSpace.create(space_id, "agent-a", "bwrap")
        b = TmpSpace.create(space_id, "agent-b", "bwrap")
        File.write!(Path.join(a, "a.txt"), "a")
        File.write!(Path.join(b, "b.txt"), "b")

        assert :ok = TmpSpace.cleanup(space_id, "agent-a", "bwrap")

        refute File.exists?(a)
        assert File.dir?(space_dir)
        assert File.read!(Path.join(b, "b.txt")) == "b"

        # A sibling can still be created after the cleanup: the space
        # dir (a shared parent) was not rmdir'd.
        c = TmpSpace.create(space_id, "agent-c", "bwrap")
        assert File.dir?(c)
      end)
    end

    test "never removes the space dir, even when the last agent goes", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        TmpSpace.create(space_id, "only-agent", "bwrap")
        assert :ok = TmpSpace.cleanup(space_id, "only-agent", "bwrap")
        assert File.dir?(space_dir)
      end)
    end

    test "refuses a hostile agent name instead of escaping the space dir", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        # A real agent dir first, so the refusals below are checked
        # against something that exists.
        keeper = TmpSpace.create(space_id, "keeper", "bwrap")
        assert Path.dirname(keeper) == space_dir

        # ".." would pass a *syntactic* `Path.dirname/1` guard and
        # `rm_rf` the whole shared `nest-<ospid>` root (every space,
        # every agent's scratch). "a/b" would nest a path. `create/2`
        # refuses both outright (the DB boundary rejects such a name, so
        # this only happens if a caller skipped it)...
        assert_raise ArgumentError, fn -> TmpSpace.create(space_id, "..", "bwrap") end
        assert_raise ArgumentError, fn -> TmpSpace.create(space_id, "a/b", "bwrap") end

        # ...and `cleanup/2` (which runs from `terminate/2`, so it must
        # never raise) logs the refusal and removes nothing.
        assert :ok = TmpSpace.cleanup(space_id, "..", "bwrap")
        assert :ok = TmpSpace.cleanup(space_id, "a/b", "bwrap")

        assert File.dir?(keeper)
        assert File.dir?(space_dir)
      end)
    end
  end

  describe "prompt_mounts/4" do
    test "names the agent's real scratch, space and backend", %{space_id: space_id} do
      mounts = TmpSpace.prompt_mounts("/ws", space_id, unique("agent-a"), "docker")

      # The scratch directory is named even though nothing created it: the
      # docker backend can only stage a script the container reaches through the
      # scratch bind, and composing the prompt runs the sandbox (see
      # `Nest.Sandbox.Backend.Docker.command/3`).
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
      mounts = TmpSpace.prompt_mounts(nil, space_id, name, "none")

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
      mounts = TmpSpace.prompt_mounts(nil, space_id, name, "none")
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
      # prompt for it — but this must not raise on the way there.
      for name <- ["..", "a/b", "with space", ""] do
        assert Mounts.scratch(TmpSpace.prompt_mounts(nil, space_id, name, "bwrap")) == nil
      end
    end
  end

  describe "the \"none\" marker" do
    test "create/3 marks a none agent's scratch and leaves the other backends unmarked", %{
      space_id: space_id
    } do
      for backend <- ["none", "bwrap", "docker"] do
        name = unique("#{backend}-a")
        if backend == "none", do: track_none_scratch(space_id, name)

        path = TmpSpace.create(space_id, name, backend)
        marked = File.exists?(Path.join(path, ".nest-scratch"))

        assert marked == (backend == "none"),
               "#{backend} scratch marked=#{marked}, expected #{backend == "none"}"
      end
    end

    test "create/3 refuses to adopt a directory that is not Nest's", %{space_id: space_id} do
      # `mkdir_p!` is a no-op on an existing directory, so without this check
      # `create/3` would claim exactly the directories the marker exists to
      # protect — and stamp the marker into one, which is what licenses the next
      # `cleanup/3` to delete it.
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

    test "cleanup/3 refuses an unmarked directory, whatever it is called", %{space_id: space_id} do
      # The name rule alone cannot tell Nest's directory from the host's: a
      # `"none"` agent named `nest-<pid>` would take another BEAM's whole scratch
      # root, and `X11-unix` / `snap-private-tmp` are real `/tmp` entries that
      # pass the same rule.
      dirs =
        for prefix <- ["nest-rmtest", "X11-unix-rmtest", "snap-private-tmp-rmtest"] do
          dir = host_tmp_dir(prefix)
          File.write!(Path.join(dir, "host-file"), "not Nest's")
          dir
        end

      # The refusal is an `:error` line — a directory that exists and is not
      # Nest's is worth an operator's attention — so the test that provokes it
      # captures and asserts it rather than letting it into the suite output.
      # Inclusion only: `capture_log` collects every process's lines.
      log =
        capture_log(fn ->
          Enum.each(dirs, fn dir ->
            assert :ok = TmpSpace.cleanup(space_id, Path.basename(dir), "none")
          end)
        end)

      assert log =~ "it is not a Nest scratch directory"

      Enum.each(dirs, fn dir ->
        assert File.dir?(dir), "#{dir} was removed without Nest's marker"
        assert File.read!(Path.join(dir, "host-file")) == "not Nest's"
      end)
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
      assert :ok = TmpSpace.remove_stale(space_id, "a/b", "none")
    end

    test "a bwrap scratch is removed without a marker", %{space_id: space_id} do
      # Its path already carries `nest-<BEAM pid>/space-<id>`, so there is
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

      capture_log(fn ->
        a = TmpSpace.create(space_id, "agent-a", "bwrap")
        b = TmpSpace.create(space_id, "agent-b", "bwrap")

        # Agent A writes into its own scratch dir. This is the shape the
        # `Overflow` writers produce (a direct host write).
        File.write!(Path.join(a, "report.txt"), "shared result\n")

        # B's sandbox sees the same /tmp (the space dir), so A's file is
        # readable at /tmp/agent-a/report.txt. `ls /tmp` shows both agents
        # sit under the one bound root.
        assert {:ok, out} =
                 Sandbox.run("cat /tmp/agent-a/report.txt && ls /tmp", Mounts.new(ws, b), caps)

        assert out =~ "shared result"
        assert out =~ "agent-a"

        # A write to /tmp lands under the space dir; the host /tmp is
        # shadowed and untouched. (This, not `write_allowed?/3`, is the
        # real enforcement — `write_allowed?/3` has no production caller;
        # the bwrap mount is the gate.)
        leak = "leak-#{System.unique_integer([:positive])}"
        assert {:ok, _} = Sandbox.run("echo x > /tmp/#{leak}", Mounts.new(ws, b), caps)

        assert File.read!(Path.join(space_dir, leak)) == "x\n"
        refute File.exists?(Path.join("/tmp", leak))
      end)
    end
  end
end
