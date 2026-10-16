defmodule Nest.Sandbox.Backend.DockerTest do
  @moduledoc """
  The docker backend: the container's name and layout, the derived image, and the
  lifecycle — all against a fake runner, so the suite never talks to a daemon.

  `Docker.system/1` (the `System.cmd("docker", argv)` default) is the one line
  these tests do not execute; `config/test.exs` installs an inert runner for the
  test environment so nothing else can reach a daemon by accident.
  """

  use ExUnit.Case, async: true

  alias Nest.Sandbox
  alias Nest.Sandbox.Backend
  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.Mounts

  @space_id 7
  @calls {__MODULE__, :docker_calls}

  # ---- fixtures ----

  defp mounts(workspace \\ nil, scratch \\ nil) do
    Mounts.new(workspace, scratch, "docker", @space_id)
  end

  # A scratch directory with the real shape, so `Paths.scratch_root/1` derives the
  # space dir rather than refusing it.
  defp scratch do
    Path.join([
      "/tmp",
      "nest-docker-test-#{System.unique_integer([:positive])}",
      "space-#{@space_id}",
      "agent-a"
    ])
  end

  defp caps(opts \\ []) do
    %{
      "net" => Keyword.get(opts, :net, false),
      "fs" => %{
        "read" => ["/"],
        "write" => Keyword.get(opts, :write, ["/tmp", ":workspace"])
      }
    }
  end

  defp caps_with(extra) do
    Map.put(caps(), "fs", Map.merge(caps()["fs"], extra))
  end

  defp caps_with_packages(packages) do
    Map.put(caps(), "sandbox", %{"packages" => packages})
  end

  # ---- the fake daemon ----

  # Every runner call in these tests is synchronous and from the test process, so
  # the process dictionary is the whole record of what the daemon was asked to do
  # — which is the observable these tests assert on.
  defp scripted_runner(answers) do
    Process.put(@calls, [])

    fn argv ->
      Process.put(@calls, [argv | Process.get(@calls, [])])

      key = Enum.find(Map.keys(answers), :default, &List.starts_with?(argv, &1))
      Map.get(answers, key, {"", 0})
    end
  end

  # A runner whose answer may depend on how many calls came before it, for the
  # races (create/build refused because someone else got there first).
  defp sequenced_runner(fun) do
    Process.put(@calls, [])

    fn argv ->
      seen = Process.get(@calls, [])
      Process.put(@calls, [argv | seen])
      fun.(argv, length(seen) + 1)
    end
  end

  defp calls, do: Enum.reverse(Process.get(@calls, []))

  # ---- container identity ----

  describe "container_name/3" do
    test "is stable for one layout and moves when any part of it does" do
      write = scratch()

      assert {:ok, name} = Docker.container_name(mounts("/ws", write), caps(), [])
      assert name =~ ~r/\Anest-space-#{@space_id}-[0-9a-f]{8}\z/

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
      # staged script unreadable inside the container. A fresh container is the
      # correct answer, and the old one goes when the space is archived.
      this_beam = Path.join(["/tmp", "nest-999999", "space-#{@space_id}", "agent-a"])
      next_beam = Path.join(["/tmp", "nest-1000000", "space-#{@space_id}", "agent-a"])

      assert {:ok, first} = Docker.container_name(mounts("/ws", this_beam), caps(), [])
      assert {:ok, second} = Docker.container_name(mounts("/ws", next_beam), caps(), [])
      refute second == first
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

  describe "command/3" do
    test "is docker exec with the container, stdin and the staged script" do
      assert {:ok, %{command: command, cd: nil}} =
               Docker.command(mounts("/ws", scratch()), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert command =~
               ~r/\Adocker exec -i nest-space-7-[0-9a-f]{8} \/bin\/bash '\/tmp\/\.cmds\/nest-cmd-1\.sh'\z/
    end

    test "escapes a script path that needs it" do
      assert {:ok, %{command: command}} =
               Docker.command(mounts("/ws", scratch()), caps(), "/tmp/.cmds/it's.sh")

      assert command =~ ~r/'\/tmp\/\.cmds\/it'\\''s\.sh'\z/
    end

    test "reports a container that cannot be created instead of returning one" do
      # The image is there (the default answer), `run` is refused, and the
      # re-inspect still says missing — so this is a real failure, not a race.
      runner =
        scripted_runner(%{["inspect"] => {"No such object\n", 1}, ["run"] => {"boom\n", 1}})

      assert {:error, reason} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert reason =~ "docker run failed"
      assert reason =~ "boom"
    end
  end

  # ---- the lifecycle ----

  describe "ensure_container/3" do
    test "reuses a running container without touching the image" do
      runner = scripted_runner(%{["inspect"] => {"running\n", 0}})
      write = scratch()

      assert {:ok, name} = Docker.ensure_container(mounts("/ws", write), caps(), runner: runner)
      assert {:ok, ^name} = Docker.ensure_container(mounts("/ws", write), caps(), runner: runner)

      # Two inspects, no create: that is what "shared by the space" means.
      assert calls() == [
               ["inspect", "--format", "{{.State.Status}}", name],
               ["inspect", "--format", "{{.State.Status}}", name]
             ]
    end

    test "starts an existing but stopped container" do
      runner = scripted_runner(%{["inspect"] => {"exited\n", 0}, ["start"] => {"", 0}})

      assert {:ok, name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert calls() == [
               ["inspect", "--format", "{{.State.Status}}", name],
               ["start", name]
             ]
    end

    test "creates the container when it is missing, building the image first" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"No such image\n", 1},
          ["build"] => {"", 0},
          ["run"] => {"container-id\n", 0}
        })

      write = scratch()

      assert {:ok, name} = Docker.ensure_container(mounts("/ws", write), caps(), runner: runner)

      tag = Docker.image_tag(caps())

      assert [
               ["inspect", "--format", "{{.State.Status}}", ^name],
               ["image", "inspect", ^tag],
               ["build", "-t", ^tag, context],
               ["run", "-d", "--name", ^name | run_args]
             ] = calls()

      assert context =~ ~r|/nest-docker-build-\d+\z|
      assert run_args == Docker.run_args(mounts("/ws", write), caps(), tag, [])
    end

    test "skips the build when the image already exists" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["build" | _], &1))
    end

    test "adopts a container a racing agent created" do
      runner =
        sequenced_runner(fn argv, n ->
          case {argv, n} do
            {["inspect" | _], 1} -> {"No such object\n", 1}
            {["image" | _], _} -> {"", 0}
            {["run" | _], _} -> {"Conflict. The container name is already in use\n", 125}
            {["inspect" | _], _} -> {"running\n", 0}
          end
        end)

      assert {:ok, name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert name =~ ~r/\Anest-space-#{@space_id}-/
    end

    test "adopts an image a racing agent built" do
      runner =
        sequenced_runner(fn argv, n ->
          case {argv, n} do
            {["inspect" | _], 1} -> {"No such object\n", 1}
            {["image" | _], 2} -> {"No such image\n", 1}
            {["build" | _], _} -> {"", 1}
            {["image" | _], _} -> {"", 0}
            {["run" | _], _} -> {"", 0}
          end
        end)

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)
    end

    test "keeps a long daemon message bounded" do
      # A failed build prints the daemon's own diagnosis, which can be very long;
      # the agent gets the beginning of it, which is where the cause is.
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"No such image\n", 1},
          ["build"] => {String.duplicate("E: no\n", 500), 100}
        })

      assert {:error, reason} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert reason =~ "docker build failed"
      assert String.length(reason) < 600
      assert String.ends_with?(reason, "…")
    end

    test "reports a failed image build rather than a half-built sandbox" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"No such image\n", 1},
          ["build"] => {"E: Unable to locate package nodejs\n", 100}
        })

      assert {:error, reason} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert reason =~ "docker build failed"
      assert reason =~ "Unable to locate package nodejs"
    end

    test "leaves no build context behind" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert Path.wildcard(Path.join(System.tmp_dir!(), "nest-docker-build-*")) == []
    end

    test "refuses mounts that belong to no space" do
      assert {:error, reason} =
               Docker.ensure_container(Mounts.new("/ws", nil, "docker"), caps(),
                 runner: fn _argv -> {"", 0} end
               )

      assert reason =~ "needs the space"
    end
  end

  describe "remove_space/2" do
    test "removes only this space's containers, by name" do
      other = "nest-space-#{@space_id + 1}-deadbeef"

      runner =
        scripted_runner(%{
          ["ps"] => {"nest-space-#{@space_id}-aaaaaaaa\n#{other}\nnot-ours\n", 0},
          ["rm"] => {"", 0}
        })

      assert :ok = Docker.remove_space(@space_id, runner: runner)

      # The filter narrows the list and the pattern decides: another space's
      # container, and anything else the daemon happens to match, is left alone.
      assert calls() == [
               [
                 "ps",
                 "-a",
                 "--filter",
                 "name=#{Docker.container_prefix(@space_id)}",
                 "--format",
                 "{{.Names}}"
               ],
               ["rm", "-f", "nest-space-#{@space_id}-aaaaaaaa"]
             ]
    end

    test "logs a daemon failure and does not raise" do
      runner = scripted_runner(%{["ps"] => {"Cannot connect to the Docker daemon\n", 1}})

      # A failure here must not break the archive or delete that asked for it, so
      # it is logged and swallowed. Inclusion only: `capture_log` is not
      # process-scoped, so an absence assertion would test nothing.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Docker.remove_space(@space_id, runner: runner)
        end)

      assert log =~ "could not list containers for space #{@space_id}"
      assert log =~ "Cannot connect to the Docker daemon"
    end

    test "logs a container that will not go away" do
      runner =
        scripted_runner(%{
          ["ps"] => {"nest-space-#{@space_id}-aaaaaaaa\n", 0},
          ["rm"] => {"Error response from daemon: container is paused\n", 1}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Docker.remove_space(@space_id, runner: runner)
        end)

      assert log =~ "could not remove container nest-space-#{@space_id}-aaaaaaaa"
    end
  end

  # ---- classification and staging ----

  describe "classify/2" do
    test "calls the daemon's own failures a broken sandbox" do
      for stderr <- [
            "docker: Error response from daemon: No such container: nest-space-7-aaaaaaaa",
            "Error response from daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock",
            "container abc is not running"
          ] do
        assert Backend.classify(mounts(), stderr) == :sandbox_setup_failed
      end
    end

    test "leaves the command's own failures to the errno table" do
      assert Backend.classify(mounts(), "cat: /x: No such file or directory") == :enoent
      assert Backend.classify(mounts(), "cat: /x: Permission denied") == :read_permission_denied
      assert Backend.classify(mounts(), "sh: 1: nope: not found") == :read_failed
      assert Backend.classify(mounts(), "[Command timed out after 5ms]") == :read_timeout
    end
  end

  describe "staging" do
    test "stages where the container's /tmp reaches" do
      write = scratch()
      mounts = mounts("/ws", write)

      assert Docker.stage_dir(mounts) == Path.join(Path.dirname(write), ".cmds")
      assert Docker.stage_dir_sandbox(mounts) == "/tmp/.cmds"
      assert Backend.stage_dir(mounts) == Docker.stage_dir(mounts)
      assert Backend.display_name(mounts) == "docker exec"
    end
  end

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
end
