defmodule Nest.Sandbox.PathsTest do
  @moduledoc """
  Tests for `Nest.Sandbox.Paths`: the one definition of the scratch bind
  source and the sandbox-domain spelling of a scratch path.

  Pure functions, `async: true`. The load-bearing cases are the refusals in
  `scratch_root/1`: binding the host `/tmp` (or `/`) at `/tmp` inside the
  sandbox would hand the agent the whole host scratch tree — every space,
  every agent — so a `tmp_path` whose parent is one of those must raise
  rather than produce a mount.
  """
  use ExUnit.Case, async: true

  alias Nest.FSPath
  alias Nest.Sandbox
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
      refute Paths.scratch_root(path) == path
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
    test "is the inverse spelling: /tmp/<agent-name>" do
      path = tmp_path()

      assert Paths.sandbox_tmp_path(path) == Path.join("/tmp", "agent-a")
      assert Paths.sandbox_tmp_path(path) == Path.join(Paths.sandbox_root(), Path.basename(path))
    end
  end

  describe "scratch_dir/1" do
    test "is the sandbox spelling, derived from the name alone" do
      assert Paths.scratch_dir("clever-raven") == "/tmp/clever-raven"
      assert Sandbox.scratch_dir("clever-raven") == Paths.scratch_dir("clever-raven")

      # The same answer as the host-path-based spelling, for the tmp_path
      # that name produces.
      tmp_path = "/tmp/nest-1/space-7/clever-raven"
      assert Paths.scratch_dir("clever-raven") == Paths.sandbox_tmp_path(tmp_path)
    end

    test "never returns a host path" do
      refute Paths.scratch_dir("agent-a") =~ "nest-"
      refute Sandbox.scratch_dir("agent-a") =~ "space-"
    end
  end

  describe "stage_dir/1" do
    test "lives in its own subdirectory of the bound space dir" do
      path = tmp_path()
      stage = Paths.stage_dir(path)

      assert Path.dirname(stage) == Paths.scratch_root(path)
      assert Path.basename(stage) == ".cmds"
    end

    test "falls back to System.tmp_dir!/0 when there is no scratch bind" do
      assert Paths.stage_dir(nil) == Path.join(System.tmp_dir!(), ".nest-cmds")
      assert Paths.stage_dir_sandbox(nil) == Paths.stage_dir(nil)
    end

    test "inherits the refusal of scratch_root/1" do
      assert_raise ArgumentError, fn -> Paths.stage_dir("/tmp/agent-a") end
      assert_raise ArgumentError, fn -> Paths.stage_dir("/agent-a") end
    end

    test "the sandbox spelling is always under /tmp when a scratch bind exists" do
      assert Paths.stage_dir_sandbox(tmp_path()) == Path.join(Paths.sandbox_root(), ".cmds")
    end
  end

  describe "sandbox_root/0" do
    test "is the mount point, exposed through Nest.Sandbox" do
      assert Paths.sandbox_root() == "/tmp"
      assert Sandbox.sandbox_root() == Paths.sandbox_root()
    end
  end
end
