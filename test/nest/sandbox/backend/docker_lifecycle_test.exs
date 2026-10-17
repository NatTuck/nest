defmodule Nest.Sandbox.Backend.DockerLifecycleTest do
  @moduledoc """
  What the docker backend asks the daemon to do: the container's lifecycle and
  removal — all against a fake runner, so the suite never talks to a daemon.

  The pure decisions (the container's name and layout, the image, the binds, the
  `run` arguments, the command line) are in `Nest.Sandbox.Backend.DockerTest`.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.Mounts

  # The one `docker inspect` the lifecycle makes about an existing container:
  # the status *and* the layout label, in a single call. Spelled out here rather
  # than read back from the module, because it is the thing that keeps a call
  # from having to inspect twice.
  @inspect_format ~s({{.State.Status}}|{{index .Config.Labels "nest.layout"}})

  # ---- the lifecycle ----

  describe "ensure_container/3" do
    test "reuses a running container whose layout matches, in one inspect" do
      mounts = mounts("/ws")
      runner = scripted_runner(existing(mounts, caps()))

      assert {:ok, name} = Docker.ensure_container(mounts, caps(), runner: runner)
      assert {:ok, ^name} = Docker.ensure_container(mounts, caps(), runner: runner)

      # Two calls, one inspect each, no create: that is what "shared by the
      # space" means, and the layout check rides along for free.
      assert calls() == [
               ["inspect", "--format", @inspect_format, name],
               ["inspect", "--format", @inspect_format, name]
             ]
    end

    test "starts an existing but stopped container" do
      runner =
        scripted_runner(Map.put(existing(mounts("/ws"), caps(), "exited"), ["start"], {"", 0}))

      assert {:ok, name} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)

      assert calls() == [
               ["inspect", "--format", @inspect_format, name],
               ["start", name]
             ]
    end

    test "replaces a container whose layout no longer matches" do
      # A container's binds, image and network are fixed when it is created, and
      # the name is stable across restarts, so the layout cannot be in the name:
      # the label is what says a container has to be replaced rather than started.
      # Here the space could reach the network when this one was built.
      mounts = mounts("/ws")
      stale = Docker.layout(mounts, caps(net: true), [])

      runner =
        scripted_runner(%{
          ["inspect"] => {"running|#{stale}\n", 0},
          ["rm"] => {"", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, name} = Docker.ensure_container(mounts, caps(), runner: runner)

      assert [
               ["inspect", "--format", @inspect_format, ^name],
               ["rm", "-f", ^name],
               ["image", "inspect", _tag],
               ["run", "-d", "--name", ^name | _args]
             ] = calls()
    end

    test "replaces a container that carries no layout at all" do
      # One from another build of Nest, or one someone made by hand: it cannot be
      # trusted to have this call's binds, so it goes.
      runner =
        scripted_runner(%{
          ["inspect"] => {"running|\n", 0},
          ["rm"] => {"", 0},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)
      assert ["rm", "-f", _name] = call_with(["rm"])
    end

    test "refuses rather than adopting a container it could not remove" do
      # `docker rm -f` can fail (a paused container). Adopting what is left would
      # run this call in the environment the container was built for, which is
      # exactly what the layout check just said it must not do.
      mounts = mounts("/ws")
      stale = Docker.layout(mounts, caps(net: true), [])

      runner =
        scripted_runner(%{
          ["inspect"] => {"running|#{stale}\n", 0},
          ["rm"] => {"Error response from daemon: container is paused\n", 1}
        })

      # The failure is logged by the removal *and* returned, so the caller can
      # report it; capture the line rather than letting it print. Inclusion only:
      # `capture_log` is not process-scoped, so an absence assertion would test
      # nothing.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, reason} = Docker.ensure_container(mounts, caps(), runner: runner)
          assert reason =~ "docker rm -f failed"
          assert reason =~ "container is paused"
        end)

      assert log =~ "could not remove container"
      refute call_with(["run"])
    end

    test "creates the container when it is missing, building the image first" do
      mounts = mounts("/ws")
      caps = caps()

      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"No such image\n", 1},
          ["build"] => {"", 0},
          ["run"] => {"container-id\n", 0}
        })

      assert {:ok, name} = Docker.ensure_container(mounts, caps, runner: runner)

      tag = Docker.image_tag(caps)

      assert [
               ["inspect", "--format", @inspect_format, ^name],
               ["image", "inspect", ^tag],
               ["build", "-t", ^tag, context],
               ["run", "-d", "--name", ^name | run_args]
             ] = calls()

      assert context =~ ~r|/nest-docker-build-\d+\z|
      assert run_args == Docker.run_args(mounts, caps, tag, [])
    end

    test "skips the build when the image already exists" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)

      refute Enum.any?(calls(), &match?(["build" | _], &1))
    end

    test "adopts a container a racing agent created" do
      # Two agents can resolve to the same container and race to create it. A
      # refused `run` because the name is taken is "someone else got there
      # first" — and they built it for the same layout, because the name is a
      # function of the space.
      mounts = mounts("/ws")
      layout = Docker.layout(mounts, caps(), [])

      runner =
        sequenced_runner(fn argv, n ->
          case {argv, n} do
            {["inspect" | _], 1} -> {"No such object\n", 1}
            {["image" | _], _} -> {"", 0}
            {["run" | _], _} -> {"Conflict. The container name is already in use\n", 125}
            {["inspect" | _], _} -> {"running|#{layout}\n", 0}
          end
        end)

      assert {:ok, name} = Docker.ensure_container(mounts, caps(), runner: runner)
      assert name == Docker.container_name(mounts) |> elem(1)
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

      assert {:ok, _name} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)
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

      assert {:error, reason} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)

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

      assert {:error, reason} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)

      assert reason =~ "docker build failed"
      assert reason =~ "Unable to locate package nodejs"
    end

    test "reports a container that cannot be created instead of returning one" do
      # The image is there (the default answer), `run` is refused, and the
      # re-inspect still says missing — so this is a real failure, not a race.
      runner =
        scripted_runner(%{["inspect"] => {"No such object\n", 1}, ["run"] => {"boom\n", 1}})

      assert {:error, reason} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)

      assert reason =~ "docker run failed"
      assert reason =~ "boom"
    end

    test "leaves no build context behind" do
      runner =
        scripted_runner(%{
          ["inspect"] => {"No such object\n", 1},
          ["image"] => {"", 0},
          ["run"] => {"", 0}
        })

      assert {:ok, _name} = Docker.ensure_container(mounts("/ws"), caps(), runner: runner)

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
      mine = "nest-space-#{space_id()}-nest_dev"
      other_installation = "nest-space-#{space_id()}-nest_test"
      other_space = "nest-space-#{space_id() + 1}-nest_dev"

      runner =
        scripted_runner(%{
          ["ps"] => {"#{mine}\n#{other_installation}\n#{other_space}\nnot-ours\n", 0},
          ["rm"] => {"", 0}
        })

      assert :ok = Docker.remove_space(space_id(), runner: runner)

      # The filter narrows the list and the pattern decides: every installation
      # of *this* space (archiving a space releases all of them), and nothing
      # else the daemon's substring filter happened to match.
      assert calls() == [
               [
                 "ps",
                 "-a",
                 "--filter",
                 "name=#{Docker.container_prefix(space_id())}",
                 "--format",
                 "{{.Names}}"
               ],
               ["rm", "-f", mine],
               ["rm", "-f", other_installation]
             ]
    end

    test "leaves a name that is not this space's exact shape" do
      # The prefix alone is not enough: what follows it has to be a name segment.
      strangers = [
        "nest-space-#{space_id()}-",
        "nest-space-#{space_id()}-!!",
        "nest-space-#{space_id() + 1}-nest_dev",
        "not-a-nest-container"
      ]

      runner =
        scripted_runner(%{["ps"] => {Enum.join(strangers, "\n") <> "\n", 0}, ["rm"] => {"", 0}})

      assert :ok = Docker.remove_space(space_id(), runner: runner)
      refute Enum.any?(calls(), &match?(["rm" | _], &1))
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
      name = "nest-space-#{space_id()}-nest_dev"

      runner =
        scripted_runner(%{
          ["ps"] => {"#{name}\n", 0},
          ["rm"] => {"Error response from daemon: container is paused\n", 1}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Docker.remove_space(space_id(), runner: runner)
        end)

      assert log =~ "could not remove container #{name}"
    end
  end
end
