defmodule Nest.Sandbox.PathsTest do
  @moduledoc """
  Tests for `Nest.Sandbox.Paths`: the one definition of the scratch bind
  source and the sandbox-side path for a scratch dir.

  Pure functions, `async: true`. The load-bearing cases are the refusals in
  `scratch_root/1`: binding the host `/tmp` (or `/`) at `/tmp` inside the
  sandbox would hand the agent the whole host scratch tree — every space,
  every agent — so a `tmp_path` whose parent is one of those must raise
  rather than produce a mount.
  """
  use ExUnit.Case, async: true

  alias Nest.FSPath
  alias Nest.Sandbox
  alias Nest.Sandbox.Installation
  alias Nest.Sandbox.Paths

  defp tmp_path do
    unique = System.unique_integer([:positive])
    Path.join([System.tmp_dir!(), "nest-paths-test-#{unique}", "space-7", "agent-a"])
  end

  describe "scratch_root/1" do
    test "returns the canonical parent of the agent's own scratch dir" do
      path = tmp_path()

      # The *space* dir is what is bound at /tmp, so the bind source is the
      # parent of the agent's own dir — canonicalised, because it becomes a
      # bwrap mount source.
      assert Paths.scratch_root(path) == FSPath.canonical(Path.dirname(path))
    end

    test "refuses a bind root of / (the whole host filesystem)" do
      # `tmp_path` of "/agent-a" means the space dir would be "/".
      assert_raise ArgumentError, ~r|refusing to use "/" as a scratch bind root|, fn ->
        Paths.scratch_root("/agent-a")
      end
    end

    test "refuses a bind root of /tmp (the host scratch root)" do
      # `tmp_path` directly under /tmp means the space dir would be /tmp
      # itself: the bind would expose every space and every agent's scratch.
      assert_raise ArgumentError, ~r|refusing to use "/tmp" as a scratch bind root|, fn ->
        Paths.scratch_root("/tmp/agent-a")
      end
    end
  end

  describe "sandbox_tmp_path/1" do
    test "maps the host scratch path to /tmp/<agent-name>" do
      path = tmp_path()

      assert Paths.sandbox_tmp_path(path) == Path.join("/tmp", "agent-a")
    end
  end

  describe "scratch_dir/1" do
    test "is the sandbox path, derived from the name alone" do
      assert Paths.scratch_dir("clever-raven") == "/tmp/clever-raven"

      # The same answer as the derived path, for the scratch dir that
      # name produces.
      scratch = "/tmp/nest-1/space-7/clever-raven"
      assert Paths.scratch_dir("clever-raven") == Paths.sandbox_tmp_path(scratch)
    end
  end

  describe "stage_dir/1" do
    test "lives inside the agent's own scratch dir, one per agent" do
      path = tmp_path()
      stage = Paths.stage_dir(path)

      # Per-agent staging: the transcript is reclaimed with the agent that
      # staged it, so the staging dir is a child of the agent's own scratch,
      # not a sibling shared by the whole space.
      assert Path.dirname(stage) == path
      assert Path.basename(stage) == ".cmds"
      assert Paths.stage_subdir() == Path.basename(stage)

      sibling = Path.join(Path.dirname(path), "agent-b")
      refute Paths.stage_dir(sibling) == stage
    end

    test "falls back to System.tmp_dir!/0 when there is no scratch bind" do
      assert Paths.stage_dir(nil) == Path.join(System.tmp_dir!(), ".nest-cmds")
      assert Paths.stage_dir_sandbox(nil) == Paths.stage_dir(nil)
    end

    test "a scratch directly under /tmp stages inside itself" do
      # Staging is a join into the agent's own dir, not a bind derivation, so
      # the `scratch_root/1` refusal does not apply: a `"none"`-shaped scratch
      # stages in its own `.cmds` like any other.
      assert Paths.stage_dir("/tmp/agent-a") == "/tmp/agent-a/.cmds"
    end

    test "the sandbox path is the agent's own scratch path plus the staging dir" do
      assert Paths.stage_dir_sandbox(tmp_path()) == "/tmp/agent-a/.cmds"

      assert Paths.stage_dir_sandbox(tmp_path()) ==
               Path.join(Paths.sandbox_tmp_path(tmp_path()), ".cmds")
    end
  end

  describe "the docker staging directory" do
    test "is one directory per space and installation, bound at /tmp/.cmds" do
      assert Paths.docker_stage_dir(7) ==
               Path.join([
                 System.tmp_dir!(),
                 "nest-docker-#{Installation.segment()}-space-7",
                 ".cmds"
               ])

      # Keyed on the space, never on the BEAM's pid: the container that binds it
      # outlives a restart, so the directory it binds has to as well.
      refute Paths.docker_stage_dir(7) == Paths.docker_stage_dir(8)

      assert Paths.docker_stage_dir_sandbox() == "/tmp/.cmds"
    end
  end

  describe "sandbox_root/0" do
    test "is the mount point, exposed through Nest.Sandbox" do
      assert Paths.sandbox_root() == "/tmp"
      assert Sandbox.sandbox_root() == Paths.sandbox_root()
    end
  end
end
