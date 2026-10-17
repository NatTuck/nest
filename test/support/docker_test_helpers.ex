defmodule Nest.Sandbox.Backend.DockerTestHelpers do
  @moduledoc """
  Fixtures for the docker backend's tests, and the fake daemon they run against.

  Shared by `Nest.Sandbox.Backend.DockerTest` (what the backend decides) and
  `Nest.Sandbox.Backend.DockerLifecycleTest` (what it asks the daemon to do), so
  the two agree on the caps they build and on how a call is recorded.
  """

  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.{Mounts, Paths}

  @space_id 7
  @agent "agent-a"
  @calls {__MODULE__, :docker_calls}

  @doc "The space these fixtures belong to."
  def space_id, do: @space_id

  @doc """
  A `Mounts` value for a `"docker"` call in this space.

  The scratch is the *container's* `/tmp/<agent>` — the one scratch spelling an
  agent ever names, and a path nothing on the host holds (see
  `Nest.Sandbox.Mounts.host_scratch?/1`).
  """
  def mounts(workspace \\ nil, scratch \\ default_scratch()) do
    Mounts.new(workspace, scratch, "docker", @space_id)
  end

  @doc "The scratch directory a docker call's mounts carry."
  def default_scratch, do: Path.join(Paths.sandbox_root(), @agent)

  @doc "The host staging directory this space's command transcripts go in."
  def stage_dir, do: Paths.docker_stage_dir(@space_id)

  @doc """
  The argv answers for a container that is already there and was built for
  `mounts` + `caps`.

  `docker inspect --format '{{.State.Status}}|{{…nest.layout}}'` is the *one*
  call the lifecycle makes about an existing container — status and layout in
  the same call — so "the container is running and matches this call" is exactly
  this answer.
  """
  def existing(mounts, caps, status \\ "running") do
    %{["inspect"] => {"#{status}|#{Docker.layout(mounts, caps, [])}\n", 0}}
  end

  @doc "The argv answers for a container that is not there."
  def missing, do: %{["inspect"] => {"No such object\n", 1}}

  @doc """
  Caps for a docker mode: the network and the two symbolic writes by default.
  """
  def caps(opts \\ []) do
    %{
      "net" => Keyword.get(opts, :net, false),
      "fs" => %{
        "read" => ["/"],
        "write" => Keyword.get(opts, :write, ["/tmp", ":workspace"])
      }
    }
  end

  @doc "Caps with extra `fs` keys merged in (project mounts, protected paths)."
  def caps_with(extra), do: Map.put(caps(), "fs", Map.merge(caps()["fs"], extra))

  @doc "Caps carrying a project's declared docker packages."
  def caps_with_packages(packages), do: Map.put(caps(), "sandbox", %{"packages" => packages})

  @doc """
  A workspace directory under `_build/tmp`, removed when the test ends.

  The `.nest` the docker backend reads its project mounts from is a file in the
  workspace, so a test that means "this project declares a mount" has to have a
  real one.
  """
  def workspace(name \\ "nest_docker_ws") do
    dir =
      Path.join([File.cwd!(), "_build", "tmp", "#{name}_#{System.unique_integer([:positive])}"])

    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn ->
      # Guarded by the identifying string, as SMELLS.md requires of any `rm_rf`.
      if String.contains?(dir, name), do: File.rm_rf(dir)
    end)

    dir
  end

  @doc """
  A runner answering from a map of argv prefixes, recording every call.

  Every runner call in these tests is synchronous and from the test process, so
  the process dictionary is the whole record of what the daemon was asked to do —
  which is the observable these tests assert on.
  """
  def scripted_runner(answers) do
    Process.put(@calls, [])

    fn argv ->
      Process.put(@calls, [argv | Process.get(@calls, [])])

      key = Enum.find(Map.keys(answers), :default, &List.starts_with?(argv, &1))
      Map.get(answers, key, {"", 0})
    end
  end

  @doc """
  A runner whose answer may depend on how many calls came before it, for the
  races (a `run`/`build` refused because someone else got there first).
  """
  def sequenced_runner(fun) do
    Process.put(@calls, [])

    fn argv ->
      seen = Process.get(@calls, [])
      Process.put(@calls, [argv | seen])
      fun.(argv, length(seen) + 1)
    end
  end

  @doc "Every argv the runner was asked for, oldest first."
  def calls, do: Enum.reverse(Process.get(@calls, []))

  @doc """
  The argv of the first recorded call matching `prefix`.
  """
  def call_with(prefix), do: Enum.find(calls(), &List.starts_with?(&1, prefix))

  @doc """
  The payload a `docker exec` command line hands the container's bash.

  A built command is `docker exec -i <name> /bin/bash -c '<payload>'`, and the
  payload is escaped as one shell word for the BEAM's own command parser. That is
  a layer the *container* never sees, so an assertion about what the container
  runs reads better against the payload — where the paths carry exactly the one
  escaping the container's bash needs.
  """
  def payload(command) do
    [_, escaped] = String.split(command, " /bin/bash -c ", parts: 2)
    escaped = String.trim(escaped)
    inner = binary_part(escaped, 1, byte_size(escaped) - 2)
    String.replace(inner, "'\\''", "'")
  end

  @doc "The container name these fixtures resolve to."
  def name, do: Docker.container_name(mounts("/ws")) |> elem(1)
end
