defmodule Nest.SandboxProjectTest do
  use ExUnit.Case, async: true

  alias Nest.Sandbox

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_sbproj_#{System.unique_integer([:positive])}")
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
    {:ok, args} = Sandbox.build(caps([mount], []), ws, nil)
    assert ["--bind", "/data/x", "/data/x"] = find_bind(args, "--bind", "/data/x")
  end

  test "tmp project mount binds its source at the dest", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    src = Path.join(dir, "src")
    mount = %{"dest" => "/data/y", "mode" => "tmp", "create" => false, "source" => src}
    {:ok, args} = Sandbox.build(caps([mount], []), ws, nil)
    assert ["--bind", ^src, "/data/y"] = find_bind(args, "--bind", src)
  end

  test "protected .nest is ro-bound after the workspace bind", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    nest = Path.join(ws, ".nest")
    File.write!(nest, "")
    prot = [%{"path" => nest, "source" => nest}]
    {:ok, args} = Sandbox.build(caps([], prot), ws, nil)
    assert ["--ro-bind", ^nest, ^nest] = find_bind(args, "--ro-bind", nest)
    assert Enum.find_index(args, &(&1 == nest)) > Enum.find_index(args, &(&1 == ws))
  end

  test "a missing .nest is masked with /dev/null", %{dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    nest = Path.join(ws, ".nest")
    prot = [%{"path" => nest, "source" => "/dev/null"}]
    {:ok, args} = Sandbox.build(caps([], prot), ws, nil)
    assert ["--ro-bind", "/dev/null", ^nest] = find_bind(args, "--ro-bind", "/dev/null")
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
    assert {:ok, "hello"} = Sandbox.read(Path.join(dest, "f.txt"), caps, ws, nil)
    assert {:ok, _} = Sandbox.stat(Path.join(dest, "f.txt"), caps, ws, nil)
  end
end
