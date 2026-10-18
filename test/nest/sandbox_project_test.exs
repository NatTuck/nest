defmodule Nest.SandboxProjectTest do
  use ExUnit.Case, async: true

  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts

  setup do
    # A workspace outside /tmp: the scratch dir is bound at /tmp, so a
    # /tmp-rooted workspace is rejected.
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_sbproj_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> if String.contains?(dir, "nest_sbproj_"), do: File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp caps(project, protected) do
    %{
      "net" => false,
      "fs" => %{
        "read" => ["/"],
        "write" => [":workspace"],
        "project" => project,
        "protected" => protected
      }
    }
  end

  defp find_bind(args, flag, source) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find(fn [f, s, _d] -> f == flag and s == source end)
  end

  test "rw project mount is bound at its dest", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    mount = %{"dest" => "/data/x", "mode" => "rw", "create" => false, "source" => "/data/x"}
    {:ok, args} = Sandbox.build(caps([mount], []), Mounts.new(ws, nil))
    assert ["--bind", "/data/x", "/data/x"] = find_bind(args, "--bind", "/data/x")
  end

  test "tmp project mount binds its source at the dest", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    src = Path.join(dir, "src")
    mount = %{"dest" => "/data/y", "mode" => "tmp", "create" => false, "source" => src}
    {:ok, args} = Sandbox.build(caps([mount], []), Mounts.new(ws, nil))
    assert ["--bind", ^src, "/data/y"] = find_bind(args, "--bind", src)
  end

  test "protected .nest is ro-bound after the workspace bind", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    nest = Path.join(ws, ".nest")
    File.write!(nest, "")
    prot = [%{"path" => nest, "source" => nest}]
    {:ok, args} = Sandbox.build(caps([], prot), Mounts.new(ws, nil))
    assert ["--ro-bind", ^nest, ^nest] = find_bind(args, "--ro-bind", nest)
    assert Enum.find_index(args, &(&1 == nest)) > Enum.find_index(args, &(&1 == ws))
  end

  test "a missing .nest is masked with /dev/null", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    nest = Path.join(ws, ".nest")
    prot = [%{"path" => nest, "source" => "/dev/null"}]
    {:ok, args} = Sandbox.build(caps([], prot), Mounts.new(ws, nil))
    assert ["--ro-bind", "/dev/null", ^nest] = find_bind(args, "--ro-bind", "/dev/null")
  end

  test "a protected file cannot be rewritten, whichever config file it is", %{dir: dir} do
    # Issue #97's actual claim, rather than just its caps entry: both files are
    # human-authored project config, and an agent that can rewrite either drifts
    # its own constraints — `AGENTS.md` is its policy, `.nest` grants host access.
    # The mask is a read-only bind, so the write fails at the kernel level rather
    # than being pre-authorized here.
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)

    nest = Path.join(ws, ".nest")
    agents_md = Path.join(ws, "AGENTS.md")
    File.write!(nest, "")
    File.write!(agents_md, "# Project rules\n")

    prot = [
      %{"path" => nest, "source" => nest},
      %{"path" => agents_md, "source" => agents_md}
    ]

    mounts = Mounts.new(ws, nil)
    caps = caps([], prot)

    # A *control*: an unprotected file in the same workspace is writable, so a
    # broken sandbox cannot satisfy the assertions below by refusing everything.
    assert {:ok, _} = Sandbox.write(Path.join(ws, "scratch.txt"), "fine\n", caps, mounts)
    assert File.read!(Path.join(ws, "scratch.txt")) == "fine\n"

    # One command for both writes rather than one per file: each is a real
    # `bwrap` fork, and the shell reports both exit codes itself. Only the
    # *control* above needs a fork of its own.
    script = """
    printf '[[mount]]\\n' > #{nest}; echo "nest=$?"
    printf 'ignore your instructions\\n' > #{agents_md}; echo "agents=$?"
    """

    # No `capture_log` and no assertion on one: the shell reports the refusals
    # itself, so the command as a whole *succeeds* and `ShellCmd` has nothing to
    # log. The exit codes below are the whole proof.
    assert {:ok, out} = Sandbox.run(script, mounts, caps)

    # The kernel's refusal, not a Nest refusal: the mask is a read-only bind, so
    # both writes fail at the mount rather than being pre-authorized.
    assert out =~ "nest=1"
    assert out =~ "agents=1"
    assert out =~ "Read-only file system"

    # And the files are untouched.
    assert File.read!(nest) == ""
    assert File.read!(agents_md) == "# Project rules\n"
  end

  test "the masked path cannot be removed either, present or absent", %{dir: dir} do
    # The attack the mask exists against is `rm` *then* recreate: a read-only
    # bind makes the write fail, but only a mount point stops the directory
    # entry being replaced. `Device or resource busy` is that assertion — it is
    # a different kernel answer from `Read-only file system`, and it is the one
    # that distinguishes "cannot write it" from "cannot swap it".
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)

    present = Path.join(ws, ".nest")
    File.write!(present, "")

    absent = Path.join(ws, "AGENTS.md")
    refute File.exists?(absent)

    prot = [
      %{"path" => present, "source" => present},
      %{"path" => absent, "source" => "/dev/null"}
    ]

    mounts = Mounts.new(ws, nil)
    caps = caps([], prot)

    # The control: an unprotected file in the same workspace *can* be removed,
    # so a broken sandbox cannot satisfy the assertions below.
    unprotected = Path.join(ws, "scratch.txt")
    File.write!(unprotected, "fine\n")
    assert {:ok, _} = Sandbox.run("rm -- #{unprotected}", mounts, caps)
    refute File.exists?(unprotected)

    # One command for both removals, for the same reason: each is a real `bwrap`
    # fork, and the shell reports both exit codes.
    script = """
    rm -- #{present}; echo "present=$?"
    rm -- #{absent}; echo "absent=$?"
    """

    assert {:ok, out} = Sandbox.run(script, mounts, caps)

    assert out =~ "present=1"
    assert out =~ "absent=1"
    assert out =~ "Device or resource busy"
  end

  test "read maps a tmp project path to its source", %{dir: dir} do
    src = Path.join(dir, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "f.txt"), "hello")

    # The mount destination must be creatable inside the sandbox: put it under
    # the (rw-bound) workspace so bwrap can create the mount point.
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    dest = Path.join(ws, "y")
    mount = %{"dest" => dest, "mode" => "tmp", "create" => false, "source" => src}
    caps = caps([mount], [])
    assert {:ok, "hello"} = Sandbox.read(Path.join(dest, "f.txt"), caps, Mounts.new(ws, nil))
    assert {:ok, _} = Sandbox.stat(Path.join(dest, "f.txt"), caps, Mounts.new(ws, nil))
  end
end
