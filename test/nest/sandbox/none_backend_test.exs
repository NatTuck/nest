defmodule Nest.Sandbox.NoneBackendTest do
  @moduledoc """
  The `"none"` backend end to end: commands really run on the host, an agent's
  `/tmp/<name>` really is the host's `/tmp/<name>`, and the staging directory
  is the one path that works without a scratch bind.

  This is the backend that enforces nothing, so the point of these tests is
  that it *does* run and that it does not pretend otherwise — not that it
  sandboxes anything.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.Paths
  alias Nest.Tools.ShellCmd

  defp caps do
    %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}}
  end

  setup do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_none_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)

    # A `"none"` space's scratch dir is the host's `/tmp/<name>`, so the name
    # has to be unique per test (the name rule the creation boundary enforces
    # is what makes that true in production).
    space_id = System.unique_integer([:positive])
    name = "none-agent-#{System.unique_integer([:positive])}"
    scratch = TmpSpace.create(space_id, name, "none")

    on_exit(fn ->
      if String.contains?(dir, "nest_none_test"), do: File.rm_rf(dir)
      TmpSpace.cleanup(space_id, name, "none")
    end)

    %{dir: dir, scratch: scratch, mounts: Mounts.new(dir, scratch, "none")}
  end

  describe "the bare command" do
    test "runs on the host and starts in the workspace", %{dir: dir, mounts: mounts} do
      assert {:ok, output} = ShellCmd.execute("pwd", mounts, caps())
      assert String.trim(output) == dir
    end

    test "round-trips stdout and the exit code", %{mounts: mounts} do
      assert {:ok, "hi\n"} = ShellCmd.execute("echo hi", mounts, caps())

      assert {:error, message} = ShellCmd.execute("echo boom >&2; exit 3", mounts, caps())
      assert message =~ "Exit code 3"
      assert message =~ "boom"
    end

    test "stages the transcript where no scratch bind exists, and removes it", %{mounts: mounts} do
      stage = Paths.stage_dir(nil)

      assert Sandbox.Backend.stage_dir(mounts) == stage
      assert Sandbox.Backend.stage_dir_sandbox(mounts) == stage

      before = Path.wildcard(Path.join(stage, "nest-cmd-*.sh"))
      assert {:ok, _output} = ShellCmd.execute("true", mounts, caps())
      assert Path.wildcard(Path.join(stage, "nest-cmd-*.sh")) == before
    end

    test "a command with no workspace still runs", %{scratch: scratch} do
      assert {:ok, "ok\n"} = ShellCmd.execute("echo ok", Mounts.new(nil, scratch, "none"), caps())
    end
  end

  describe "the agent's /tmp is the host's /tmp" do
    test "TmpSpace roots a none space at the real /tmp" do
      assert TmpSpace.space_dir(1, "none") == "/tmp"
      assert TmpSpace.agent_dir(1, "agent-a", "none") == "/tmp/agent-a"
      refute TmpSpace.space_dir(1, "bwrap") == "/tmp"
    end

    test "a write under the scratch dir lands in the real /tmp", %{
      scratch: scratch,
      mounts: mounts
    } do
      assert scratch == Path.join("/tmp", Path.basename(scratch))
      target = Path.join(scratch, "report.txt")

      assert {:ok, _output} = Sandbox.write(target, "hello", caps(), mounts)
      assert File.read!(target) == "hello"
    end

    test "read, stat and glob all see the host", %{dir: dir, mounts: mounts} do
      File.write!(Path.join(dir, "a.txt"), "aaa")

      assert {:ok, "aaa"} = Sandbox.read(Path.join(dir, "a.txt"), caps(), mounts)
      assert {:ok, %File.Stat{size: 3}} = Sandbox.stat(Path.join(dir, "a.txt"), caps(), mounts)
      assert {:ok, [found]} = Sandbox.glob(Path.join(dir, "*.txt"), caps(), mounts)
      assert found == Path.join(dir, "a.txt")
    end

    test "a failed read is classified from the command's own stderr", %{dir: dir, mounts: mounts} do
      assert {:error, :enoent} = Sandbox.read(Path.join(dir, "missing.txt"), caps(), mounts)
    end
  end
end
