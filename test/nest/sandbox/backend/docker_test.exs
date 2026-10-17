defmodule Nest.Sandbox.Backend.DockerTest do
  @moduledoc """
  What the docker backend *decides*: the container's name and layout, the derived
  image, the binds it makes, the `run` arguments, the command line, and
  classification.

  `Docker.system/1` (the `System.cmd("docker", argv)` default) is the one line the
  suite does not execute; `config/test.exs` installs an inert runner for the test
  environment, so nothing else can reach a daemon by accident — and that inert
  runner is a daemon that always succeeds, which is why a *pure* assertion about
  the command line can go through `Docker.command/3` here. What the backend then
  asks the daemon to *do* is in `Nest.Sandbox.Backend.DockerLifecycleTest`.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.FSPath
  alias Nest.Sandbox
  alias Nest.Sandbox.Backend
  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.{Binds, Installation, Mounts, Paths}
  alias Nest.Tools.ShellEscape

  # ---- container identity ----

  describe "container_name/1" do
    test "is the space and the installation, and nothing per-BEAM" do
      assert {:ok, name} = Docker.container_name(mounts("/ws"))
      assert name == "nest-space-#{space_id()}-#{Installation.segment()}"

      # Another agent, another scratch, another workspace: the *same* container.
      # Nothing per-BEAM is bound any more, which is what lets it outlive a BEAM
      # restart — and what makes every agent of a space share one environment.
      assert {:ok, ^name} = Docker.container_name(mounts("/ws", "/tmp/agent-b"))
      assert {:ok, ^name} = Docker.container_name(mounts("/other-ws"))
    end

    test "refuses mounts that belong to no space" do
      assert {:error, reason} = Docker.container_name(Mounts.new("/ws", nil, "docker"))

      assert reason =~ "needs the space"
    end
  end

  describe "layout/3" do
    test "moves when the network, the binds, the devices or the image does" do
      mounts = mounts("/ws")
      layout = Docker.layout(mounts, caps(), [])

      assert layout =~ ~r/\A[0-9a-f]{12}\z/
      assert Docker.layout(mounts, caps(), []) == layout

      for {other_mounts, other_caps, other_devices} <- [
            {mounts("/ws"), caps(net: true), []},
            {mounts("/ws"), caps(), ["/dev/accel0"]},
            {mounts("/ws"), caps_with_packages(["nodejs"]), []}
          ] do
        refute Docker.layout(other_mounts, other_caps, other_devices) == layout
      end
    end

    test "does not move for a per-call difference the container's superset covers" do
      # Two modes of one space, one writing the workspace and one not. The
      # container serves both, so its layout must not move between them —
      # otherwise every alternation between the two modes would remove and
      # recreate it.
      mounts = mounts("/ws")

      assert Docker.layout(mounts, caps(), []) == Docker.layout(mounts, caps(write: []), [])
    end

    test "does not move for another agent's scratch" do
      # The scratch is the container's own `/tmp/<agent>`, which the container
      # does not bind at all — it is the sandbox inside it that makes the agent's
      # directory. So one container serves every agent of a space, which is what
      # "one container per space" means.
      mounts = mounts("/ws")

      assert Docker.layout(mounts, caps(), []) ==
               Docker.layout(mounts("/ws", "/tmp/agent-b"), caps(), [])
    end

    test "moves when the project's mounts do" do
      # `.nest` is read per call, and a project mount is part of the container's
      # binds: a `.nest` that declares one has to be a different container.
      plain = workspace("nest_docker_layout")
      with_mount = workspace("nest_docker_layout")

      File.write!(Path.join(with_mount, ".nest"), """
      [[mount]]
      path = "data"
      mode = "rw"
      """)

      refute Docker.layout(mounts(plain), caps(), []) ==
               Docker.layout(mounts(with_mount), caps(), [])
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

    test "bubblewrap is in the base set, because the sandbox runs inside the container" do
      # Not optional: the container is half the sandbox. The mode's caps are
      # enforced by a bwrap *inside* it, so an image without one runs nothing.
      assert "bubblewrap" in Docker.packages(caps())
      assert Docker.dockerfile(caps()) =~ "bubblewrap"
    end
  end

  # ---- what the container binds ----

  describe "container_binds/1" do
    test "binds the workspace read-write and the .nest mask read-only" do
      assert Docker.container_binds(mounts("/ws")) == [
               {"/ws", "/ws", :rw},
               {"/dev/null", "/ws/.nest", :ro}
             ]
    end

    test "never binds a host path over the container's own /tmp" do
      # The scratch bind's source under docker is `/tmp` — a path *inside* the
      # container — so a container that rendered it literally would replace its
      # own `/tmp` with the host's, and every agent's scratch would become the
      # host's. It is the sandbox inside the container that needs that bind, to
      # set `/tmp`'s mode.
      for {source, _dest, _mode} <- Docker.container_binds(mounts("/ws")) do
        refute source == Paths.sandbox_root()
      end
    end

    test "binds what a workspace-writing mode gets, for the modes that get less" do
      # The container's binds cannot be the ones a single call's caps ask for:
      # one container serves every mode the space can run. They are the binds of
      # a mode that writes the workspace — which is exactly the set `.nest`
      # project mounts are granted to — and a read-only call sees them read-only,
      # because the sandbox inside only re-binds what its own caps ask for.
      workspace = workspace("nest_docker_binds")

      File.write!(Path.join(workspace, ".nest"), """
      [[mount]]
      path = "data"
      mode = "rw"
      """)

      File.mkdir_p!(Path.join(workspace, "data"))

      binds = Docker.container_binds(mounts(workspace))

      assert {Path.join(workspace, "data"), Path.join(workspace, "data"), :rw} in binds
      assert {Path.join(workspace, ".nest"), Path.join(workspace, ".nest"), :ro} in binds
    end

    test "binds nothing but the mask when the call has no workspace" do
      assert Docker.container_binds(mounts()) == []
    end
  end

  describe "run_args/4" do
    test "is the flags, the network, the label, the binds, the directory and the image" do
      mounts = mounts("/ws")
      layout = Docker.layout(mounts, caps(), [])

      assert Docker.run_args(mounts, caps(), "nest-sandbox:abc", []) == [
               "--cap-add",
               "SYS_ADMIN",
               "--security-opt",
               "apparmor=unconfined",
               "--security-opt",
               "seccomp=unconfined",
               "--network",
               "none",
               "--label",
               "nest.layout=#{layout}",
               "-v",
               "/ws:/ws:rw",
               "-v",
               "/dev/null:/ws/.nest:ro",
               "-v",
               "#{stage_dir()}:/tmp/.cmds:ro",
               "-w",
               "/ws",
               "nest-sandbox:abc",
               "sleep",
               "infinity"
             ]
    end

    test "stages read-only, so the agent cannot write into the host's staging dir" do
      # The agent can write `/tmp`, so a writable staging bind would be a host
      # write path — and one that could rewrite a sibling agent's pending script
      # between the BEAM writing it and the container running it.
      assert "#{stage_dir()}:/tmp/.cmds:ro" in Docker.run_args(mounts("/ws"), caps(), "img", [])
    end

    test "the network flag is the space's, and there is no flag when it may reach it" do
      assert "--network" in Docker.run_args(mounts("/ws"), caps(), "img", [])
      refute "--network" in Docker.run_args(mounts("/ws"), caps(net: true), "img", [])
    end

    test "passes HPU devices through, and omits the directory when there is none" do
      args = Docker.run_args(mounts(), caps(), "img", ["/dev/accel0", "/dev/accel1"])

      assert Enum.take(args, -7) == [
               "--device",
               "/dev/accel0",
               "--device",
               "/dev/accel1",
               "img",
               "sleep",
               "infinity"
             ]

      refute "-w" in args
    end
  end

  # ---- the command line ----

  describe "command/3" do
    test "is docker exec with -c, the container, and the inner sandbox" do
      assert {:ok, %{command: command, cd: nil}} =
               Docker.command(mounts("/ws"), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      # `-c` is load-bearing: the payload is a command, not a script path.
      assert command =~ ~r/\Adocker exec -i nest-space-#{space_id()}-[^ ]+ \/bin\/bash -c '/
      assert payload(command) =~ "exec bwrap"
      assert payload(command) =~ "--ro-bind / /"
      assert payload(command) =~ "--dev-bind /dev /dev"
      assert payload(command) =~ "--proc /proc"
      # No namespace of its own: a user namespace is what made earlier attempts
      # fail at `pivot_root`, and bwrap's own loopback setup fails without one.
      refute payload(command) =~ "--unshare"
    end

    test "makes the agent's scratch directory inside the container" do
      # The scratch is the container's own `/tmp/<agent>`, so nothing on the host
      # can make it and the command that runs has to.
      assert {:ok, %{command: command}} =
               Docker.command(mounts("/ws"), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert payload(command) =~ "mkdir -p '/tmp/agent-a'"
      assert payload(command) =~ "&& exec bwrap"
    end

    test "tightens the container's binds per call, by setting their mode" do
      # The container has already put each bind at its destination, so what the
      # sandbox inside has to do is set that path's *mode*: `--ro-bind / /` made
      # everything read-only and a read-only bind cannot be upgraded from inside.
      assert {:ok, %{command: writable}} =
               Docker.command(mounts("/ws"), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert {:ok, %{command: read_only}} =
               Docker.command(mounts("/ws"), caps(write: []), "/tmp/.cmds/nest-cmd-1.sh")

      assert payload(writable) =~ "--bind '/ws' '/ws'"
      assert payload(writable) =~ "--bind '/tmp' '/tmp'"
      assert payload(read_only) =~ "--ro-bind '/ws' '/ws'"
      assert payload(read_only) =~ "--ro-bind '/tmp' '/tmp'"
      refute payload(read_only) =~ "--bind '/ws' '/ws'"
      # And not merely the two expected self-binds: a read-only call's payload must
      # contain no `--bind` at all. `--ro-bind / /` is recursive *and* recursively
      # read-only, so a stray `--bind` is exactly what would loosen it.
      refute payload(read_only) =~ "--bind"
    end

    test "starts in the workspace, and in the scratch root when there is none" do
      assert {:ok, %{command: with_ws}} =
               Docker.command(mounts("/ws"), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert payload(with_ws) =~ "--chdir '/ws'"

      assert {:ok, %{command: without_ws}} =
               Docker.command(mounts(), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert payload(without_ws) =~ "--chdir '/tmp'"
    end

    test "escapes a path that needs it" do
      # Two shell layers read this: the BEAM's command parser, which sees the
      # whole payload as one quoted argument, and the container's bash, which
      # runs it. A path with a quote in it has to survive both.
      ws = Path.join(workspace("nest_docker_escape"), "it's a ws")
      File.mkdir_p!(ws)

      assert {:ok, %{command: command}} = Docker.command(mounts(ws), caps(), "/tmp/.cmds/it's.sh")

      assert payload(command) =~ "--chdir " <> ShellEscape.escape(ws)
      assert payload(command) =~ ShellEscape.escape("/tmp/.cmds/it's.sh")
    end

    test ~s(refuses a `mode = "tmp"` .nest mount, by name, and says the way out) do
      # A `mode = "tmp"` mount is backed by a directory Nest makes, and its source
      # is derived from the scratch root — which on this backend names a path
      # *inside the container*. The source that comes out is therefore a host path,
      # which the daemon would create as root, and a container's binds are fixed at
      # creation and shared by the whole space, so that directory would be one
      # agent's and every other agent in the space would write into it.
      caps =
        caps_with(%{
          "project" => [
            %{"mode" => "rw", "dest" => "/proj/data", "source" => "/proj/data"},
            %{
              "mode" => "tmp",
              "dest" => "/proj/build",
              "source" => "/tmp/agent-a/project/df5ca6c5eb41b38e"
            }
          ]
        })

      assert {:error, reason} = Docker.command(mounts("/ws"), caps, "/tmp/.cmds/x.sh")

      assert reason =~ "/proj/build"
      # `mode = "rw"` binds a path the container already has, so it is unaffected.
      refute reason =~ "/proj/data"
      assert reason =~ ~s(mode = "rw")
    end

    test ~s(the container's binds drop a `mode = "tmp"` .nest mount, rather than binding a host path) do
      # The refusal above reads the *call's* caps, but a container's binds are
      # fixed when it is created and are derived from a synthetic caps that always
      # writes `":workspace"` — so the project mounts are merged in for every
      # space, including one whose calling mode (`plan`) is granted none.
      # Refusing per call would therefore still let `ensure_container` emit
      # `-v <container scratch>/project/<slug>:<dest>:rw`: the daemon would create
      # that host directory as root, and one container serves the whole space, so
      # every agent in it would write into the first agent's directory. The spec
      # has to be dropped at the container.
      ws = workspace("nest_docker_tmp_bind")

      File.write!(Path.join(ws, ".nest"), """
      [[mount]]
      path = "build"
      mode = "tmp"

      [[mount]]
      path = "data"
      mode = "rw"
      """)

      mounts = mounts(ws)
      binds = Docker.container_binds(mounts)
      scratch_project = Path.join(Mounts.scratch(mounts), "project") <> "/"

      refute Enum.any?(binds, fn {source, _dest, _mode} ->
               String.starts_with?(source, scratch_project)
             end)

      # `mode = "rw"` binds a path the container already has, so it survives.
      dests = Enum.map(binds, fn {_source, dest, _mode} -> dest end)
      assert FSPath.canonical(Path.join(ws, "data")) in dests
    end

    test "a background job gets the same refusals, instead of failing inside the container" do
      # `ShellJobs.Launcher` builds a job through `job_spec/4`, never through
      # `command/3`, so without its own check it would be the one path that
      # skipped both refusals. The failure would then surface from the inner
      # bwrap as `Can't bind mount …: No such file or directory`, which
      # classifies as an ordinary `:enoent` and reads to the agent as a missing
      # file rather than as a sandbox restriction it can act on.
      unbound = caps_with(%{"write" => ["/tmp", ":workspace", "/var/cache/thing"]})

      assert {:error, unbound_reason} =
               Docker.job_spec(mounts("/ws"), unbound, "/tmp/.cmds/x.sh", "/tmp/agent-a/job.log")

      assert unbound_reason =~ "/var/cache/thing"

      tmp_mount =
        caps_with(%{
          "project" => [
            %{
              "mode" => "tmp",
              "dest" => "/proj/build",
              "source" => "/tmp/agent-a/project/df5ca6c5eb41b38e"
            }
          ]
        })

      assert {:error, tmp_reason} =
               Docker.job_spec(
                 mounts("/ws"),
                 tmp_mount,
                 "/tmp/.cmds/x.sh",
                 "/tmp/agent-a/job.log"
               )

      assert tmp_reason =~ "/proj/build"
    end

    test "refuses a write path the container does not have, by name" do
      # A `caps.fs.write` path outside the symbolic entries and the `.nest`
      # mounts names a host path the container does not have, so the sandbox
      # inside cannot bind it. Letting it fail would be a `bwrap: Can't bind
      # mount …: No such file or directory`, which classifies as an ordinary
      # `:enoent` and reads to the agent as a missing file.
      caps = caps_with(%{"write" => ["/tmp", ":workspace", "/var/cache/thing"]})

      assert {:error, reason} = Docker.command(mounts("/ws"), caps, "/tmp/.cmds/x.sh")
      assert reason =~ "/var/cache/thing"
      assert reason =~ ".nest"
    end

    test "refuses mounts that belong to no space" do
      assert {:error, reason} =
               Docker.command(
                 Mounts.new("/ws", "/tmp/agent-a", "docker"),
                 caps(),
                 "/tmp/.cmds/x.sh"
               )

      assert reason =~ "needs the space"
    end
  end

  describe "job_spec/4" do
    test "tees the job's output into the container's own log, and keeps the exit code" do
      log = "/tmp/agent-a/shell-jobs/job-1.log"

      assert {:ok, %{command: command, cd: nil}} =
               Docker.job_spec(mounts("/ws"), caps(), "/tmp/.cmds/nest-cmd-1.sh", log)

      # The log is the container's, so the command writes it — and its
      # directory, which the scratch's own `mkdir -p` does not cover.
      assert payload(command) =~ "mkdir -p '/tmp/agent-a' '/tmp/agent-a/shell-jobs'"
      assert payload(command) =~ "2>&1 | tee '#{log}'"

      # Without `pipefail` the pipeline's status would be `tee`'s, and a job that
      # failed would report exit 0.
      assert payload(command) =~ "set -o pipefail; "
    end

    test "needs no daemon call, and no scratch to stage the transcript" do
      # `command/3` has already ensured the container, and the name is a pure
      # function of the mounts.
      assert {:ok, %{command: command}} =
               Docker.job_spec(mounts("/ws"), caps(), "/tmp/.cmds/x.sh", "/tmp/agent-a/j.log")

      assert command =~ "nest-space-#{space_id()}-#{Installation.segment()}"

      assert {:error, reason} =
               Docker.job_spec(Mounts.new("/ws", nil, "docker"), caps(), "/x.sh", "/tmp/l.log")

      assert reason =~ "needs the space"
    end
  end

  # ---- the shared bind list ----

  describe "the shared bind list" do
    test "bwrap renders exactly the specs, after its readable roots" do
      # Both binding backends derive their binds from `Nest.Sandbox.Binds`, so
      # there is one derivation and two renderings rather than two derivations
      # with a drift guard. This pins bwrap's rendering; the docker rendering is
      # pinned by the command-line and `run_args` tests above. The readable roots
      # are bwrap's own prefix — docker does not bind them, because the image is
      # its read set.
      caps =
        caps_with(%{
          "write" => ["/tmp", ":workspace", "/var/cache/thing"],
          "project" => [%{"source" => "/host/data", "dest" => "/ws/data"}],
          "protected" => [%{"source" => "/dev/null", "path" => "/ws/.nest"}]
        })

      workspace = workspace("nest_docker_render")
      mounts = Mounts.new(workspace, "/tmp/nest-1/space-7/agent-a", "bwrap")

      {:ok, args} = Sandbox.build(caps, mounts)

      assert bwrap_binds(args) ==
               readable_roots(caps) ++
                 Enum.map(Binds.specs(caps, mounts), fn {source, dest, mode} ->
                   {source, dest, to_string(mode)}
                 end)
    end

    test "docker's inner sandbox renders the same specs, one self-bind each" do
      caps =
        caps_with(%{
          "write" => ["/tmp", ":workspace"],
          "project" => [%{"source" => "/host/data", "dest" => "/ws/data"}],
          "protected" => [%{"source" => "/dev/null", "path" => "/ws/.nest"}]
        })

      mounts = mounts("/ws")

      assert {:ok, %{command: command}} = Docker.command(mounts, caps, "/tmp/.cmds/x.sh")

      for {_source, dest, mode} <- Binds.specs(caps, mounts) do
        flag = if mode == :rw, do: "--bind", else: "--ro-bind"
        assert payload(command) =~ "#{flag} '#{dest}' '#{dest}'"
      end
    end
  end

  # ---- classification and staging ----

  describe "classify/2" do
    test "calls the daemon's own failures a broken sandbox" do
      for stderr <- [
            "docker: Error response from daemon: No such container: nest-space-7-x",
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
    test "is one host directory per space, bound at /tmp/.cmds inside the container" do
      mounts = mounts("/ws")

      assert Docker.stage_dir(mounts) == Paths.docker_stage_dir(space_id())
      assert Docker.stage_dir_sandbox(mounts) == "/tmp/.cmds"
      assert Backend.stage_dir(mounts) == Docker.stage_dir(mounts)
      assert Backend.display_name(mounts) == "docker exec"
    end

    test "is the same directory before and after a restart, and per installation" do
      # Keyed on the space rather than on the BEAM's pid, which is what lets the
      # container that binds it outlive a restart.
      assert Paths.docker_stage_dir(space_id()) == Paths.docker_stage_dir(space_id())
      refute Paths.docker_stage_dir(space_id()) == Paths.docker_stage_dir(space_id() + 1)
      assert Paths.docker_stage_dir(space_id()) =~ Installation.segment()
    end

    test "falls back to the no-bind spelling for a call with no space" do
      # Such a call cannot run at all (`command/3` refuses it), so this only has
      # to be total.
      assert Docker.stage_dir(Mounts.new("/ws", nil, "docker")) == Paths.stage_dir(nil)
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
