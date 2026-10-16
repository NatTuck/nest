defmodule Nest.Sandbox.BackendTest do
  @moduledoc """
  The backend seam: the value that names a backend (`Mounts`), the dispatch
  (`Backend.resolve/1` and the four accessors), and the two implementations
  this stage ships (`bwrap` and `none`).
  """

  use ExUnit.Case, async: true

  alias Nest.Sandbox
  alias Nest.Sandbox.Backend
  alias Nest.Sandbox.Backend.{Bwrap, None}
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.Paths
  alias Nest.Spaces.Space

  defp caps do
    %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}}
  end

  setup do
    # A workspace outside /tmp: the bwrap backend rejects a /tmp-rooted one.
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_backend_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)

    on_exit(fn ->
      if String.contains?(dir, "nest_backend_test"), do: File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  describe "the backend on a Mounts value" do
    test "new/2 takes the default backend", %{dir: dir} do
      mounts = Mounts.new(dir, nil)

      assert Mounts.backend(mounts) == Space.default_sandbox_backend()
      assert Space.default_sandbox_backend() in Space.sandbox_backends()
    end

    test "new/3 names the backend and keeps both directories", %{dir: dir} do
      mounts = Mounts.new(dir, "/tmp/none-space/agent-a", "none")

      assert Mounts.backend(mounts) == "none"
      assert Mounts.workspace(mounts) == dir
      assert Mounts.scratch(mounts) == "/tmp/none-space/agent-a"
    end

    test "from_agent/1 is the agent's own value", %{dir: dir} do
      mounts = Mounts.new(dir, nil, "none")

      assert Mounts.from_agent(%Nest.Agents.Agent{mounts: mounts}) == mounts
    end
  end

  describe "resolve/1" do
    test "resolves the backends this build implements" do
      assert {:ok, Bwrap} = Backend.resolve(Mounts.new(nil, nil, "bwrap"))
      assert {:ok, None} = Backend.resolve(Mounts.new(nil, nil, "none"))
    end

    test "reports a backend this build does not implement instead of guessing" do
      assert {:error, message} = Backend.resolve(Mounts.new(nil, nil, "podman"))
      assert message =~ "podman"
    end

    test "reports docker as not implemented yet, rather than as unknown" do
      # `docker` is a value the schema offers (`Space.sandbox_backends/0`) whose
      # implementation has not landed: a space created with it must be told what
      # is actually missing. `Nest.Sandbox.Backend.Docker` replaces this clause,
      # and this test with it.
      assert {:error, message} = Backend.resolve(Mounts.new(nil, nil, "docker"))
      assert message =~ "docker"
      assert message =~ "not implemented"
    end
  end

  describe "Bwrap" do
    test "produces the bwrap command line and leaves the directory to bwrap", %{dir: dir} do
      mounts = Mounts.new(dir, nil)

      assert {:ok, spec} = Bwrap.command(mounts, caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert spec.cd == nil
      assert String.starts_with?(spec.command, "bwrap ")
      assert spec.command =~ "--unshare-all"
      assert String.ends_with?(spec.command, " /bin/bash '/tmp/.cmds/nest-cmd-1.sh'")
    end

    test "stages inside the bound space scratch dir", %{dir: dir} do
      mounts = Mounts.new(dir, "/tmp/nest-1/space-7/agent-1")

      assert Bwrap.stage_dir(mounts) == "/tmp/nest-1/space-7/.cmds"
      assert Bwrap.stage_dir_sandbox(mounts) == "/tmp/.cmds"
    end

    test "names itself in an operator log" do
      assert Bwrap.display_name(Mounts.new(nil, nil)) == "bwrap"
    end

    test "classifies bwrap's own setup failures" do
      mounts = Mounts.new(nil, nil)

      assert Backend.classify(mounts, "bwrap: Can't find source path /x: No such file") ==
               :sandbox_setup_failed

      assert Backend.classify(mounts, "cat: /x: No such file or directory") == :enoent
    end
  end

  describe "None" do
    test "produces the bare command and names the directory to start it in", %{dir: dir} do
      mounts = Mounts.new(dir, "/tmp/agent-a", "none")

      assert {:ok, spec} = None.command(mounts, caps(), "/tmp/.nest-cmds/nest-cmd-1.sh")

      refute spec.command =~ "bwrap"
      assert spec.command == "/bin/bash '/tmp/.nest-cmds/nest-cmd-1.sh'"
      assert spec.cd == dir
    end

    test "stages where there is no bind to translate through" do
      mounts = Mounts.new(nil, "/tmp/agent-a", "none")
      stage = Paths.stage_dir(nil)

      assert None.stage_dir(mounts) == stage
      assert None.stage_dir_sandbox(mounts) == stage
      assert Backend.stage_dir(mounts) == stage
      assert Backend.stage_dir_sandbox(mounts) == stage
    end

    test "names itself in an operator log" do
      assert None.display_name(Mounts.new(nil, nil, "none")) == "the bare command"
    end

    test "never reports a sandbox setup failure" do
      mounts = Mounts.new(nil, nil, "none")

      # A bare command has no setup phase, so a command that merely prints
      # bwrap's marker text must not be read as a broken sandbox.
      assert Backend.classify(mounts, "bwrap: Can't find source path /x") == :read_failed
      assert Backend.classify(mounts, "echo: write error") == :read_failed
      assert Backend.classify(mounts, "cat: /x: No such file or directory") == :enoent
      assert Backend.classify(mounts, "cat: /x: Permission denied") == :read_permission_denied
    end

    test "classifies the annotations ShellCmd writes into stderr" do
      mounts = Mounts.new(nil, nil, "none")

      assert Backend.classify(mounts, "[Command timed out after 5ms]") == :read_timeout
      assert Backend.classify(mounts, "[Command cancelled]") == :read_cancelled
    end
  end

  describe "ShellCmd dispatch" do
    test "an unknown backend is reported to the caller, not raised", %{dir: dir} do
      mounts = Mounts.new(dir, nil, "podman")

      assert {:error, message} = Sandbox.run("true", mounts, caps())
      assert message =~ "podman"
    end
  end
end
