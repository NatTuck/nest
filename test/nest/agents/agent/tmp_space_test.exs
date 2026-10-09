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

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox

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
    space_dir = TmpSpace.space_dir(space_id)
    %{space_id: space_id, space_dir: space_dir}
  end

  describe "create/2" do
    test "creates a per-agent dir under one shared space dir", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        a = TmpSpace.create(space_id, "agent-a")
        b = TmpSpace.create(space_id, "agent-b")

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
        first = TmpSpace.create(space_id, "agent-a")
        assert TmpSpace.create(space_id, "agent-a") == first
      end)
    end
  end

  describe "cleanup/2" do
    test "removes only the agent's own dir, leaving the space + siblings", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        a = TmpSpace.create(space_id, "agent-a")
        b = TmpSpace.create(space_id, "agent-b")
        File.write!(Path.join(a, "a.txt"), "a")
        File.write!(Path.join(b, "b.txt"), "b")

        assert :ok = TmpSpace.cleanup(space_id, "agent-a")

        refute File.exists?(a)
        assert File.dir?(space_dir)
        assert File.read!(Path.join(b, "b.txt")) == "b"

        # A sibling can still be created after the cleanup: the space
        # dir (a shared parent) was not rmdir'd.
        c = TmpSpace.create(space_id, "agent-c")
        assert File.dir?(c)
      end)
    end

    test "never removes the space dir, even when the last agent goes", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        TmpSpace.create(space_id, "only-agent")
        assert :ok = TmpSpace.cleanup(space_id, "only-agent")
        assert File.dir?(space_dir)
      end)
    end

    test "neutralizes a hostile agent name to a single safe segment", %{
      space_id: space_id,
      space_dir: space_dir
    } do
      capture_log(fn ->
        # ".." must not escape the space dir: `cleanup/2`'s syntactic
        # guard would otherwise `rm_rf` the whole shared `nest-<ospid>`
        # root (every space, every agent's scratch).
        dotdot = TmpSpace.create(space_id, "..")
        assert Path.dirname(dotdot) == space_dir
        refute dotdot == space_dir

        # A "/" would otherwise create a nested path.
        nested = TmpSpace.create(space_id, "a/b")
        assert Path.dirname(nested) == space_dir

        assert :ok = TmpSpace.cleanup(space_id, "..")
        refute File.exists?(dotdot)
        assert File.dir?(space_dir)

        assert :ok = TmpSpace.cleanup(space_id, "a/b")
        refute File.exists?(nested)
        assert File.dir?(space_dir)
      end)
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
      on_exit(fn -> File.rm_rf(ws) end)

      capture_log(fn ->
        a = TmpSpace.create(space_id, "agent-a")
        b = TmpSpace.create(space_id, "agent-b")

        # Agent A writes into its own scratch dir. This is the shape the
        # `Overflow` writers produce (a direct host write).
        File.write!(Path.join(a, "report.txt"), "shared result\n")

        # B's sandbox sees the same /tmp (the space dir), so A's file is
        # readable at /tmp/agent-a/report.txt. `ls /tmp` shows both agents
        # sit under the one bound root.
        assert {:ok, out} = Sandbox.run("cat /tmp/agent-a/report.txt && ls /tmp", ws, b, caps)
        assert out =~ "shared result"
        assert out =~ "agent-a"

        # A write to /tmp lands under the space dir; the host /tmp is
        # shadowed and untouched. (This, not `write_allowed?/3`, is the
        # real enforcement — `write_allowed?/3` has no production caller;
        # the bwrap mount is the gate.)
        leak = "leak-#{System.unique_integer([:positive])}"
        assert {:ok, _} = Sandbox.run("echo x > /tmp/#{leak}", ws, b, caps)

        assert File.read!(Path.join(space_dir, leak)) == "x\n"
        refute File.exists?(Path.join("/tmp", leak))
      end)
    end
  end
end
