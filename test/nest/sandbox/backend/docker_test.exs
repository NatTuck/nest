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
  alias Nest.Sandbox.Backend
  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.{Binds, Installation, Mounts, Paths}

  # ---- container identity ----

  describe "container_name/1" do
    test "is the space and the installation, and nothing per-BEAM" do
      assert {:ok, name} = Docker.container_name(mounts("/ws"))
      assert name == "nest-space-#{space_id()}-#{Installation.segment()}"

      # Another agent, another scratch, another workspace: the *same* container.
      # Nothing per-BEAM is bound any more, which is what lets it outlive a BEAM
      # restart — and what makes every agent of a space share one environment.
      # (The refusal for mounts with no space at all is pinned through
      # `command/3` below, which is the only way a production call reaches it.)
      assert {:ok, ^name} = Docker.container_name(mounts("/other-ws", "/tmp/agent-b"))
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

    test "does not move for anything per-call or per-agent" do
      # Two modes of one space, one writing the workspace and one not. The
      # container serves both, so its layout must not move between them —
      # otherwise every alternation between the two modes would remove and
      # recreate it. The scratch is the container's own `/tmp/<agent>`, which the
      # container does not bind at all — it is the sandbox inside it that makes
      # the agent's directory — so another agent's scratch does not move it
      # either. One container serves every agent of a space, which is what "one
      # container per space" means.
      mounts = mounts("/ws")
      layout = Docker.layout(mounts, caps(), [])

      assert Docker.layout(mounts, caps(write: []), []) == layout
      assert Docker.layout(mounts("/ws", "/tmp/agent-b"), caps(), []) == layout
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
      # One representative is enough — the base set either names a project
      # toolchain or it does not.
      refute Docker.dockerfile(caps()) =~ "nodejs"
    end

    test "packages/1 is the base set plus the project's, sorted and unique" do
      # `bash` is already in the base set, so the project list exercises the
      # de-duplication as well as the merge.
      packages = Docker.packages(caps_with_packages(["nodejs", "bash"]))

      assert packages == Enum.sort(packages)
      assert packages == Enum.uniq(packages)
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
    test "binds the workspace read-write, and neither config file" do
      # `.nest` and `AGENTS.md` are one class — human-authored project config the
      # agent must not rewrite — and the container binds **neither**: the bwrap
      # inside masks them per call, so a container-level copy would shadow the file
      # a human adds later (it is a `/dev/null` bind whenever the file is absent)
      # and would make `nest.layout` depend on whether the two files exist yet.
      # `Nest.Sandbox.Backend.Docker.CommandLine` renders both masks. The list is
      # exactly the workspace and nothing else — in particular no host path is
      # bound over the container's own `/tmp`: the scratch bind's source is a path
      # *inside* the container, so a container that rendered it literally would
      # replace its own `/tmp` with the host's, and every agent's scratch would
      # become the host's. It is the sandbox inside the container that needs that
      # bind, to set `/tmp`'s mode.
      assert Docker.container_binds(mounts("/ws")) == [{"/ws", "/ws", :rw}]
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
      # (That the two protected files are dropped from this superset even though
      # it names them is `Nest.Sandbox.Backend.DockerProtectedTest`'s.)
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
               "#{stage_dir()}:/tmp/.cmds:ro",
               "-w",
               "/ws",
               "nest-sandbox:abc",
               "sleep",
               "infinity"
             ]

      # The staging bind is read-only: the agent can write `/tmp`, so a writable
      # staging bind would be a host write path — and one that could rewrite a
      # sibling agent's pending script between the BEAM writing it and the
      # container running it.
      #
      # And the network flag is the space's: a space that may reach the network
      # gets no flag at all.
      refute "--network" in Docker.run_args(mounts, caps(net: true), "img", [])
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

      # `-c` is load-bearing: the payload is a command, not a script path. What
      # the payload then contains — the inner bwrap's flags, the scratch
      # `mkdir`, the per-call bind modes — is pinned as text by
      # `Nest.Sandbox.Backend.Docker.CommandLineTest`, which calls the renderer
      # directly; what is pinned here is that this backend hands it *this space's*
      # container.
      assert command =~ ~r/\Adocker exec -i nest-space-#{space_id()}-[^ ]+ \/bin\/bash -c '/
    end

    test "tightens the container's binds per call, by setting their mode" do
      # The container has already put each bind at its destination, so what the
      # sandbox inside has to do is set that path's *mode*: `--ro-bind / /` made
      # everything read-only and a read-only bind cannot be upgraded from inside.
      # The writable half is `CommandLineTest`'s; what is pinned here is that a
      # call which writes nothing gets no writable bind *at all* — `--ro-bind / /`
      # is recursive *and* recursively read-only, so a stray `--bind` is exactly
      # what would loosen it.
      assert {:ok, %{command: read_only}} =
               Docker.command(mounts("/ws"), caps(write: []), "/tmp/.cmds/nest-cmd-1.sh")

      assert payload(read_only) =~ "--ro-bind '/ws' '/ws'"
      refute payload(read_only) =~ "--bind"
    end

    test "starts in the scratch root when the call has no workspace" do
      # The workspace case is `CommandLineTest`'s exact line; this is the other
      # branch of `chdir/1`.
      assert {:ok, %{command: without_ws}} =
               Docker.command(mounts(), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert payload(without_ws) =~ "--chdir '/tmp'"
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
      # And the tmp one is gone outright, not re-sourced from some other host
      # path — the refutation above only says no bind names the scratch.
      refute FSPath.canonical(Path.join(ws, "build")) in dests
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
    test "hands the job's log inside the container to the command, which tees it there" do
      log = "/tmp/agent-a/shell-jobs/job-1.log"

      assert {:ok, %{command: command, cd: nil}} =
               Docker.job_spec(mounts("/ws"), caps(), "/tmp/.cmds/nest-cmd-1.sh", log)

      # The log is a file in the container's own `/tmp`, so the command that runs
      # is the one that has to write it. The pipeline itself (`set -o pipefail`
      # and the `tee`, and the `mkdir` for the log's directory) is pinned by
      # `Nest.Sandbox.Backend.Docker.CommandLineTest`; what is pinned here is
      # that this entry point passes the path through to it.
      assert payload(command) =~ "2>&1 | tee '#{log}'"
    end
  end

  # ---- the shared bind list ----

  describe "the shared bind list" do
    test "docker's inner sandbox renders the same specs, one self-bind each" do
      caps =
        caps_with(%{
          "write" => ["/tmp", ":workspace"],
          "project" => [%{"source" => "/host/data", "dest" => "/ws/data"}],
          "protected" => [%{"source" => "/dev/null", "path" => "/ws/.nest"}]
        })

      mounts = mounts("/ws")

      assert {:ok, %{command: command}} = Docker.command(mounts, caps, "/tmp/.cmds/x.sh")

      for {source, dest, mode} <- Binds.specs(caps, mounts) do
        # One exception: a protected file that is *absent* is bound from
        # `/dev/null`, because the container does not bind it and there is nothing
        # at the dest to self-bind. That is the same mask the bwrap backend makes.
        expected =
          if source == "/dev/null",
            do: "--ro-bind /dev/null '#{dest}'",
            else: "#{if mode == :rw, do: "--bind", else: "--ro-bind"} '#{dest}' '#{dest}'"

        assert payload(command) =~ expected
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
      # The directory's shape, its stability across a BEAM restart and its
      # per-space, per-installation key are `Nest.Sandbox.Paths`'s
      # (`test/nest/sandbox/paths_test.exs`), and the bind that carries it into
      # the container is `run_args/4`'s above. What is left here is that this
      # backend names it, and the name it logs itself under.
      mounts = mounts("/ws")

      assert Docker.stage_dir(mounts) == Paths.docker_stage_dir(space_id())
      assert Backend.display_name(mounts) == "docker exec"
    end

    test "falls back to the no-bind spelling for a call with no space" do
      # Such a call cannot run at all (`command/3` refuses it), so this only has
      # to be total.
      assert Docker.stage_dir(Mounts.new("/ws", nil, "docker")) == Paths.stage_dir(nil)
    end
  end
end
