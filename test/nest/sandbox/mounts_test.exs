defmodule Nest.Sandbox.MountsTest do
  @moduledoc """
  The mounts value: what each backend says about its scratch, and the one thing
  it creates.

  The scratch is the interesting half. Under `bwrap` and `"none"` it is a
  directory on the host; under `"docker"` it is a path *inside* the container,
  which is why everything that writes a scratch file has to ask which of the two
  it holds (`host_scratch?/1`).
  """

  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Sandbox.{Mounts, Paths}

  describe "host_scratch?/1" do
    test "is true only where the scratch really is a host directory" do
      # The `"none"` literal is the one that pins the catch-all: a clause
      # narrowed to `"bwrap"` would still pass a bwrap assertion, and a `"none"`
      # scratch is the answer a reader most plausibly gets wrong. Bwrap's own
      # answer is exercised end to end by every host-scratch test — `ShellJobs`
      # and `ShellCmd` stage and read real files under it.
      assert Mounts.host_scratch?(Mounts.new("/ws", "/tmp/agent-a", "none"))
      refute Mounts.host_scratch?(Mounts.new("/ws", "/tmp/agent-a", "docker"))
    end
  end

  describe "scratch_bind_source/1" do
    test "is the container's own /tmp for a docker call" do
      # Nothing to bind — but docker's entry still has a job: the sandbox inside
      # the container self-binds `/tmp` onto itself to set its *mode*, which is
      # what makes the scratch writable at all. A container that rendered it as a
      # bind of the host's `/tmp` would replace its own. (`"none"` takes the same
      # clause but binds nothing at all, so there is no behaviour to pin there.)
      assert Mounts.scratch_bind_source(Mounts.new("/ws", "/tmp/agent-a", "docker")) ==
               Paths.sandbox_root()
    end

    test "is nil for a call that binds no scratch" do
      # Each literal pins a different clause-ordering hazard: without the
      # `scratch: nil` clause first, docker would take the `/tmp` clause and
      # bwrap would take the fallback and raise.
      assert Mounts.scratch_bind_source(Mounts.new("/ws", nil, "bwrap")) == nil
      assert Mounts.scratch_bind_source(Mounts.new("/ws", nil, "docker")) == nil
    end
  end

  describe "ensure_scratch!/1" do
    test "creates the scratch under a backend whose scratch is a host directory" do
      # The parent chain is part of the claim, not incidental: this is the
      # re-create path (`Nest.Agents.TmpSweeper` removes a whole space dir), so
      # a `mkdir` that assumed the space dir still existed would leave the agent
      # with no scratch. The `"none"` sibling in `TmpSpaceTest` cannot pin it —
      # there the parent is `/tmp`, which always exists.
      root = Path.join(System.tmp_dir!(), "nest_mounts_#{System.unique_integer([:positive])}")
      dir = Path.join([root, "space-1", "agent-a"])
      on_exit(fn -> rm_tmp!(root, "nest_mounts_") end)

      assert :ok = Mounts.ensure_scratch!(Mounts.new("/ws", dir, "bwrap"))
      assert File.dir?(dir)
    end

    test "creates nothing on the host for a docker call" do
      # A docker scratch names a path inside the container. Creating it here
      # would make a *host* directory at a spelling the agent only ever means
      # inside the container — and the container would never see it, so the
      # agent would still have no scratch.
      name = "nest_mounts_docker_#{System.unique_integer([:positive])}"
      dir = Path.join(Paths.sandbox_root(), name)
      refute File.exists?(dir)

      assert :ok = Mounts.ensure_scratch!(Mounts.new("/ws", dir, "docker", 7))
      refute File.exists?(dir)
    end

    test "is a no-op with no scratch at all" do
      assert :ok = Mounts.ensure_scratch!(Mounts.new("/ws", nil, "docker"))
    end
  end
end
