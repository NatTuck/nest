defmodule Nest.Agents.Agent.TmpSpaceTest do
  @moduledoc """
  Space-scoped scratch-dir tests: one `/tmp` per **space**, not per agent.

  The layout is `/tmp/nest-<BEAM ospid>/space-<space_id>/<agent-name>`,
  and the **space** directory is what `Nest.Sandbox` binds at `/tmp`, so
  siblings in a space can read each other's scratch files. `async: true`:
  each test uses a fresh space id and cleans up only its own space dir.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox

  setup do
    space_id = System.unique_integer([:positive])
    space_dir = TmpSpace.space_dir(space_id)
    on_exit(fn -> File.rm_rf(space_dir) end)
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
        # ".." would otherwise escape the space dir (and, as the sandbox
        # binds the parent at /tmp, expose the whole host /tmp).
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
    test "a sibling reads another agent's file via file-read and shell-cmd", %{
      space_id: space_id
    } do
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

        # Agent A writes into its own scratch dir. This is exactly what
        # the `Overflow` writers do (a direct host write), and the path
        # they print is this host path.
        host_path = Path.join(a, "report.txt")
        File.write!(host_path, "shared result\n")

        # B reads it by the printed host path through the read-only
        # fast-path (the `file-read` tool).
        assert {:ok, "shared result\n"} = Sandbox.read(host_path, caps)

        # B also reads it inside the sandbox via shell-cmd, using the
        # path the shared space bind exposes: /tmp/<agent>/report.txt.
        # `ls /tmp` proves both agents sit under the one bound root.
        assert {:ok, out} = Sandbox.run("cat /tmp/agent-a/report.txt && ls /tmp", ws, b, caps)
        assert out =~ "shared result"
        assert out =~ "agent-a"
      end)
    end

    test "the sandbox rule helpers still refuse paths outside the space", %{
      space_id: space_id
    } do
      space_dir = TmpSpace.space_dir(space_id)
      inside = Path.join(space_dir, "agent-a/report.txt")

      caps = %{
        "net" => false,
        "fs" => %{"read" => ["/workspace"], "write" => [":workspace"]}
      }

      refute Sandbox.read_allowed?(inside, caps)
      refute Sandbox.write_allowed?(inside, caps, "/workspace")

      assert Sandbox.read_allowed?("/workspace/inside.txt", caps)
      assert Sandbox.write_allowed?("/workspace/inside.txt", caps, "/workspace")
    end
  end
end
