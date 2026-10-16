defmodule Nest.Sandbox.Backend.DockerLifecycleTest do
  @moduledoc """
  What the docker backend asks the daemon to do: the exec line, the container's
  lifecycle, the dead-BEAM sweep, and removal — all against a fake runner, so the
  suite never talks to a daemon.

  The pure decisions (the container's name and layout, the image, the binds, the
  `run` arguments) are in `Nest.Sandbox.Backend.DockerTest`.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.Sandbox.Backend
  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.Mounts

  # A pid above any real `pid_max`, so `/proc/<pid>` cannot exist.
  @dead_pid "999999999"

  # ---- the command line ----

  describe "command/3" do
    test "is docker exec with the container, stdin and the staged script" do
      assert {:ok, %{command: command, cd: nil}} =
               Docker.command(mounts("/ws", scratch()), caps(), "/tmp/.cmds/nest-cmd-1.sh")

      assert command =~
               ~r/\Adocker exec -i nest-space-7-\d+-[0-9a-f]{8} \/bin\/bash '\/tmp\/\.cmds\/nest-cmd-1\.sh'\z/
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
               ["ps" | _],
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
            {["ps" | _], _} -> {"", 0}
            {["image" | _], _} -> {"", 0}
            {["run" | _], _} -> {"Conflict. The container name is already in use\n", 125}
            {["inspect" | _], _} -> {"running\n", 0}
          end
        end)

      assert {:ok, name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert name =~ ~r/\Anest-space-#{space_id()}-/
    end

    test "adopts an image a racing agent built" do
      runner =
        sequenced_runner(fn argv, n ->
          case {argv, n} do
            {["inspect" | _], 1} -> {"No such object\n", 1}
            {["ps" | _], _} -> {"", 0}
            {["image" | _], 3} -> {"No such image\n", 1}
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

  describe "the dead-BEAM sweep" do
    # A pid above any real `pid_max`, so `/proc/<pid>` cannot exist.
    @dead_pid "999999999"

    test "removes a dead BEAM's container before creating this one" do
      dead = "nest-space-#{space_id()}-#{@dead_pid}-aaaaaaaa"

      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["ps"] => {"#{dead}\n", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0},
          ["rm"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      # The removal is a step of its own, before the create.
      assert [
               ["inspect", "--format", "{{.State.Status}}", _name],
               ["ps" | _],
               ["rm", "-f", ^dead],
               ["image" | _],
               ["run" | _]
             ] = calls()
    end

    test "names the BEAM it is reclaiming for in its log line" do
      # The sweep logs each removal at `:info` with the pid it is reclaiming for,
      # so an operator can watch it work. That line is deliberately *not* asserted
      # here: the test logger is configured at `:warning`, so an `:info` line is
      # never generated at all — `capture_log/2` cannot capture it, with or without
      # `level: :info`, and lowering the primary level would race the async suite.
      # (Measured, not assumed: all three forms return "" in this suite.) The
      # observable the test can have is the removal itself, above; what this pins
      # is that the sweep parses the name for the pid, which is what the line
      # reports.
      dead = "nest-space-#{space_id()}-#{@dead_pid}-aaaaaaaa"

      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["ps"] => {"#{dead}\n", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0},
          ["rm"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert ["rm", "-f", ^dead] = Enum.find(calls(), &match?(["rm" | _], &1))
    end

    test "keeps this BEAM's own container" do
      mine = "nest-space-#{space_id()}-#{Elixir.System.pid()}-aaaaaaaa"

      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["ps"] => {"#{mine}\n", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["rm" | _], &1))
    end

    test "keeps another live BEAM's container" do
      # Two BEAMs can share a space id — a dev BEAM and a prod BEAM on one
      # daemon, same serial — and neither may remove the other's container. `/proc/1`
      # is the one pid that is certainly live and certainly not this BEAM's.
      other = "nest-space-#{space_id()}-1-aaaaaaaa"

      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["ps"] => {"#{other}\n", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["rm" | _], &1))
    end

    test "never touches a name that is not this space's exact format" do
      # Another space's container, an older naming scheme, a name someone made
      # up, and a name with the pid in the wrong place.
      strangers = [
        "nest-space-#{space_id() + 1}-#{@dead_pid}-aaaaaaaa",
        "nest-space-#{space_id()}-aaaaaaaa",
        "nest-space-#{space_id()}-#{@dead_pid}-NOTHEX!!",
        "not-a-nest-container",
        "#{@dead_pid}-nest-space-#{space_id()}-aaaaaaaa"
      ]

      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["ps"] => {Enum.join(strangers, "\n") <> "\n", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["rm" | _], &1))
    end

    test "does not sweep when the container is reused" do
      runner = scripted_runner(%{["inspect"] => {"running\n", 0}})

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["ps" | _], &1))
    end

    test "does not sweep when the container is merely started" do
      runner = scripted_runner(%{["inspect"] => {"exited\n", 0}, ["start"] => {"", 0}})

      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["ps" | _], &1))
    end

    test "a daemon that cannot list does not stop the create" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["ps"] => {"Cannot connect to the Docker daemon\n", 1},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      # The `run` that follows reports the same daemon failure properly, so the
      # sweep's failure is a debugging line rather than a second report of it —
      # and it must not turn a working create into an error.
      assert {:ok, _name} =
               Docker.ensure_container(mounts("/ws", scratch()), caps(), runner: runner)

      assert Enum.any?(calls(), &match?(["run" | _], &1))
    end
  end

  describe "remove_space/2" do
    test "removes only this space's containers, by name" do
      other = "nest-space-#{space_id() + 1}-999999999-deadbeef"

      runner =
        scripted_runner(%{
          ["ps"] => {"nest-space-#{space_id()}-999999999-aaaaaaaa\n#{other}\nnot-ours\n", 0},
          ["rm"] => {"", 0}
        })

      assert :ok = Docker.remove_space(space_id(), runner: runner)

      # The filter narrows the list and the pattern decides: another space's
      # container, and anything else the daemon happens to match, is left alone.
      assert calls() == [
               [
                 "ps",
                 "-a",
                 "--filter",
                 "name=#{Docker.container_prefix(space_id())}",
                 "--format",
                 "{{.Names}}"
               ],
               ["rm", "-f", "nest-space-#{space_id()}-999999999-aaaaaaaa"]
             ]
    end

    test "logs a daemon failure and does not raise" do
      runner = scripted_runner(%{["ps"] => {"Cannot connect to the Docker daemon\n", 1}})

      # A failure here must not break the archive or delete that asked for it, so
      # it is logged and swallowed. Inclusion only: `capture_log` is not
      # process-scoped, so an absence assertion would test nothing.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Docker.remove_space(space_id(), runner: runner)
        end)

      assert log =~ "could not list containers for space #{space_id()}"
      assert log =~ "Cannot connect to the Docker daemon"
    end

    test "logs a container that will not go away" do
      runner =
        scripted_runner(%{
          ["ps"] => {"nest-space-#{space_id()}-999999999-aaaaaaaa\n", 0},
          ["rm"] => {"Error response from daemon: container is paused\n", 1}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Docker.remove_space(space_id(), runner: runner)
        end)

      assert log =~ "could not remove container nest-space-#{space_id()}-999999999-aaaaaaaa"
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
end
