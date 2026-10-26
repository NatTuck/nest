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

  import ExUnit.CaptureLog

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

    test "a non-zero exit is an error carrying the exit code and the stderr", %{mounts: mounts} do
      # A non-zero exit is an operator diagnostic: `ShellCmd` logs it with
      # `Logger.error` before returning, so the test that provokes it captures
      # and asserts that line rather than letting it into the suite output.
      # Inclusion only — `capture_log` collects every process's logs in the
      # window, so an absence assertion here would test nothing (SMELLS.md).
      log =
        capture_log(fn ->
          assert {:error, message} = ShellCmd.execute("echo boom >&2; exit 3", mounts, caps())
          assert message =~ "Exit code 3"
          assert message =~ "boom"
        end)

      assert log =~ "ShellCmd.execute: the bare command exited non-zero"
      assert log =~ "exit_code=3"
    end

    test "stages the transcript where no scratch bind exists, and removes it", %{mounts: mounts} do
      stage = Paths.stage_dir(nil)

      assert Sandbox.Backend.stage_dir(mounts) == stage
      assert Sandbox.Backend.stage_dir_sandbox(mounts) == stage

      # The staging directory is shared (`System.tmp_dir!()/.nest-cmds`, used by
      # every `none` space and by the no-scratch-bind case), so the observable has
      # to be *this* command's transcript and not the directory's contents: a
      # marker only this command contains, and no file in the staging directory
      # containing it afterwards. `ShellCmd` removes the transcript on every path.
      marker = "nest-none-staging-#{System.unique_integer([:positive])}"
      assert {:ok, _output} = ShellCmd.execute("echo #{marker}", mounts, caps())

      leftovers =
        stage
        |> Path.join("nest-cmd-*.sh")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          case File.read(path) do
            {:ok, content} -> String.contains?(content, marker)
            {:error, _reason} -> false
          end
        end)

      assert leftovers == []
    end

    test "a command with no workspace still runs", %{scratch: scratch} do
      assert {:ok, "ok\n"} = ShellCmd.execute("echo ok", Mounts.new(nil, scratch, "none"), caps())
    end
  end

  describe "the agent's /tmp is the host's /tmp" do
    test "TmpSpace roots a none space at the real /tmp" do
      assert TmpSpace.space_dir(1, "none") == "/tmp"
      assert TmpSpace.agent_dir(1, "agent-a", "none") == "/tmp/agent-a"
    end

    test "a write under the scratch dir lands in the real /tmp", %{
      scratch: scratch,
      mounts: mounts
    } do
      target = Path.join(scratch, "report.txt")

      assert {:ok, _output} = Sandbox.write(target, "hello", caps(), mounts)
      assert File.read!(target) == "hello"

      # A new file lands under the transcript's umask, so `file-write` (which is
      # `Sandbox.write/4`) is `0644` rather than whatever the launcher's umask
      # would have made it. Nothing else pins that claim.
      assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o644
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
