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

      assert Mounts.backend(mounts) == Backend.default()
      assert Backend.default() in Backend.backends()
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

    test "resolves every backend the list offers" do
      for backend <- Backend.backends() do
        assert {:ok, module} = Backend.resolve(Mounts.new(nil, nil, backend))
        assert is_atom(module)
      end
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

  describe "remove_space/3" do
    test "is a no-op for every backend that keeps nothing alive" do
      # Only docker keeps an environment outside the BEAM (its containers), so
      # the other two answer without asking anything. The docker clause is
      # asserted in `Nest.Sandbox.Backend.DockerTest`, where its argv is checked
      # against a fake daemon.
      assert Backend.remove_space(7, "bwrap") == :ok
      assert Backend.remove_space(7, "none") == :ok
    end
  end

  describe "the accessors" do
    test "raise on a backend this build does not implement" do
      # `command/3` reports an unknown backend as a value the agent can read; the
      # four accessors are reached only after it has resolved one, so an unknown
      # value there is a programming error rather than something to report.
      mounts = Mounts.new(nil, nil, "podman")

      for call <- [
            fn -> Backend.stage_dir(mounts) end,
            fn -> Backend.stage_dir_sandbox(mounts) end,
            fn -> Backend.display_name(mounts) end,
            fn -> Backend.classify(mounts, "boom") end
          ] do
        assert_raise ArgumentError, ~r/podman/, call
      end
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
