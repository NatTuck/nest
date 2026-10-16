defmodule Nest.Sandbox.Backend.DockerTest do
  @moduledoc """
  What the docker backend *decides*: the container's name and layout, the derived
  image, the binds it makes, the `run` arguments, classification, and staging.

  `Docker.system/1` (the `System.cmd("docker", argv)` default) is the one line the
  suite does not execute; `config/test.exs` installs an inert runner for the test
  environment so nothing else can reach a daemon by accident. What the backend
  then *asks the daemon to do* is in
  `Nest.Sandbox.Backend.DockerLifecycleTest`.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.Sandbox
  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.Mounts

  # ---- container identity ----

  describe "container_name/3" do
    test "is stable for one layout and moves when any part of it does" do
      write = scratch()

      assert {:ok, name} = Docker.container_name(mounts("/ws", write), caps(), [])
      assert name =~ ~r/\Anest-space-#{space_id()}-#{Elixir.System.pid()}-[0-9a-f]{8}\z/

      # Same layout, same name: this is what makes two agents share a container.
      assert {:ok, ^name} = Docker.container_name(mounts("/ws", write), caps(), [])

      # Every part of the signature moves it: net, the bind modes, the workspace
      # path, and the devices.
      for {other_mounts, other_caps, other_devices} <- [
            {mounts("/ws", write), caps(net: true), []},
            {mounts("/ws", write), caps(write: ["/tmp"]), []},
            {mounts("/other", write), caps(), []},
            {mounts("/ws", write), caps(), ["/dev/accel0"]}
          ] do
        assert {:ok, other} = Docker.container_name(other_mounts, other_caps, other_devices)
        refute other == name
      end
    end

    test "a new BEAM's scratch root is a new container, not a reuse" do
      # The scratch root is part of the bind list, and its path embeds the BEAM's
      # pid, so it changes on every restart. The name has to follow it: a
      # container's mounts are fixed when it is created, so `docker start`ing the
      # old one would leave its `/tmp` pointing at the *previous* BEAM's scratch
      # directory — a directory this BEAM never writes to, which would make every
      # staged script unreadable inside the container. The superseded container is
      # swept on the next create for the space (see the sweep tests below).
      this_beam = Path.join(["/tmp", "nest-999999", "space-#{space_id()}", "agent-a"])
      next_beam = Path.join(["/tmp", "nest-1000000", "space-#{space_id()}", "agent-a"])

      assert {:ok, first} = Docker.container_name(mounts("/ws", this_beam), caps(), [])
      assert {:ok, second} = Docker.container_name(mounts("/ws", next_beam), caps(), [])
      refute second == first
    end

    test "carries the BEAM pid, and the pid moves the name" do
      write = scratch()

      assert {:ok, name} = Docker.container_name(mounts("/ws", write), caps(), [], "111")
      assert name == "nest-space-#{space_id()}-111-" <> hash_suffix(name)

      assert {:ok, other} = Docker.container_name(mounts("/ws", write), caps(), [], "222")
      refute other == name
    end

    test "the image is part of the layout, so a package change moves the name" do
      # The image *is* the container's root filesystem, and `ensure_image/2` runs
      # only on the create path — so a `.nest` that changes its `[sandbox]
      # packages` has to move the name, or every command would keep reusing the
      # container built from the old image.
      write = scratch()

      assert {:ok, plain} = Docker.container_name(mounts("/ws", write), caps(), [])

      assert {:ok, packaged} =
               Docker.container_name(mounts("/ws", write), caps_with_packages(["nodejs"]), [])

      refute packaged == plain
    end

    test "refuses mounts that belong to no space" do
      assert {:error, reason} =
               Docker.container_name(Mounts.new("/ws", nil, "docker"), caps(), [])

      assert reason =~ "needs the space"
    end
  end

  # ---- the derived image ----

  describe "the derived image" do
    test "the tag follows the package set" do
      base = Docker.image_tag(caps())
      assert base =~ ~r/\Anest-sandbox:[0-9a-f]{12}\z/
      assert Docker.image_tag(caps()) == base
      refute Docker.image_tag(caps_with_packages(["nodejs"])) == base
    end

    test "the Dockerfile is the base image plus the package set" do
      dockerfile = Docker.dockerfile(caps_with_packages(["nodejs"]))

      assert dockerfile =~ "FROM debian:trixie-slim"
      assert dockerfile =~ "apt-get install -y --no-install-recommends"
      assert dockerfile =~ "rm -rf /var/lib/apt/lists/*"

      for package <- ~w(bash coreutils file git curl ca-certificates procps ripgrep nodejs) do
        assert dockerfile =~ package
      end

      # The project toolchain is deliberately not in the base: a project adds it.
      refute Docker.dockerfile(caps()) =~ "nodejs"
      refute Docker.dockerfile(caps()) =~ "elixir"
    end

    test "packages/1 is the base set plus the project's, sorted and unique" do
      packages = Docker.packages(caps_with_packages(["nodejs", "bash"]))

      assert packages == Enum.sort(packages)
      assert packages == Enum.uniq(packages)
      assert "bash" in packages
      assert "nodejs" in packages
    end
  end

  # ---- what the container binds ----

  describe "bind_specs/2" do
    test "binds the workspace and the scratch root at the mode's write flags" do
      write = scratch()

      assert Docker.bind_specs(mounts("/ws", write), caps()) == [
               {"/ws", "/ws", "rw"},
               {Path.dirname(write), "/tmp", "rw"}
             ]

      assert Docker.bind_specs(mounts("/ws", write), caps(write: [])) == [
               {"/ws", "/ws", "ro"},
               {Path.dirname(write), "/tmp", "ro"}
             ]
    end

    test "binds nothing when the call has neither a workspace nor a scratch" do
      assert Docker.bind_specs(mounts(), caps()) == []
    end

    test "binds the extra write paths, the project mounts and the .nest mask" do
      caps =
        caps_with(%{
          "write" => ["/tmp", ":workspace", "/var/cache/thing"],
          "project" => [%{"source" => "/host/data", "dest" => "/ws/data"}],
          "protected" => [%{"source" => "/dev/null", "path" => "/ws/.nest"}]
        })

      specs = Docker.bind_specs(mounts("/ws", nil), caps)

      assert {"/var/cache/thing", "/var/cache/thing", "rw"} in specs
      assert {"/host/data", "/ws/data", "rw"} in specs
      assert {"/dev/null", "/ws/.nest", "ro"} in specs
    end

    test "agrees with bwrap's binds, minus the readable roots bwrap adds" do
      # The two backends must bind the same things — only the spelling differs
      # (`--bind`/`--ro-bind` there, `-v` here). This is the guard that keeps them
      # from drifting. The readable roots (`caps.fs.read`) are the one intended
      # difference: bwrap binds the host's `/` read-only, and docker has no such
      # bind because the container's root filesystem is the image.
      caps =
        caps_with(%{
          "write" => ["/tmp", ":workspace", "/var/cache/thing"],
          "project" => [%{"source" => "/host/data", "dest" => "/ws/data"}],
          "protected" => [%{"source" => "/dev/null", "path" => "/ws/.nest"}]
        })

      workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_docker_binds"])
      File.mkdir_p!(workspace)

      on_exit(fn ->
        if String.contains?(workspace, "nest_docker_binds"), do: File.rm_rf(workspace)
      end)

      write = scratch()
      {:ok, args} = Sandbox.build(caps, Mounts.new(workspace, write))
      bwrap_binds = args |> bwrap_binds() |> Enum.reject(&(&1 in readable_roots(caps)))

      assert Enum.sort(bwrap_binds) ==
               Enum.sort(Docker.bind_specs(mounts(workspace, write), caps))
    end
  end

  describe "run_args/4" do
    test "is the network flag, the binds, the devices, the directory and the image" do
      write = scratch()

      assert Docker.run_args(mounts("/ws", write), caps(), "nest-sandbox:abc", []) == [
               "--network",
               "none",
               "-v",
               "/ws:/ws:rw",
               "-v",
               "#{Path.dirname(write)}:/tmp:rw",
               "-w",
               "/ws",
               "nest-sandbox:abc",
               "sleep",
               "infinity"
             ]

      # The default bridge when the mode allows the network.
      refute "--network" in Docker.run_args(mounts("/ws", write), caps(net: true), "img", [])
    end

    test "passes HPU devices through, and omits the directory when there is none" do
      assert Docker.run_args(mounts(), caps(), "img", ["/dev/accel0", "/dev/accel1"]) == [
               "--network",
               "none",
               "--device",
               "/dev/accel0",
               "--device",
               "/dev/accel1",
               "img",
               "sleep",
               "infinity"
             ]
    end
  end

  # ---- the command line ----

  # ---- bwrap's own argument list, read back as binds ----

  defp bwrap_binds(args), do: do_bwrap_binds(args, [])

  defp do_bwrap_binds([flag, source, dest | rest], acc) when flag in ["--bind", "--ro-bind"],
    do: do_bwrap_binds(rest, [{source, dest, bind_mode(flag)} | acc])

  defp do_bwrap_binds([_other | rest], acc), do: do_bwrap_binds(rest, acc)
  defp do_bwrap_binds([], acc), do: Enum.reverse(acc)

  defp bind_mode("--bind"), do: "rw"
  defp bind_mode("--ro-bind"), do: "ro"

  defp readable_roots(caps) do
    caps |> Sandbox.readable_roots() |> Enum.map(&{&1, &1, "ro"})
  end

  defp hash_suffix(name), do: name |> String.split("-") |> List.last()
end
